defmodule MlAccounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "users" do
    field :email, :string
    field :username, :string
    field :display_name, :string
    field :bio, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :role, :string, default: "user"
    field :confirmed_at, :utc_datetime

    # 2FA : secrets TOTP chiffrés (`MlAccounts.TwoFactor`), dernier pas de temps accepté (anti-rejeu)
    field :totp_secret, :binary, redact: true
    field :totp_pending_secret, :binary, redact: true
    field :totp_last_step, :integer
    field :totp_enabled_at, :utc_datetime

    # Données personnelles : suppression programmée (échéance), puis compte anonymisé (`MlAccounts.Privacy`)
    field :deletion_scheduled_at, :utc_datetime
    field :deleted_at, :utc_datetime

    # Fin de la restriction active la plus lointaine (`MlAccounts.Sanctions`) ; passée = plus de restriction
    field :restricted_until, :utc_datetime

    # Profil enrichi : visibilité filtrée par `MlAccounts.Profiles`, avatar = blason préréglé ou image
    # téléversée (`MlAccounts.Avatars`), jamais les deux.
    field :pronouns, :string
    field :interests, {:array, :string}, default: []
    field :cover, :string
    field :profile_visibility, :string, default: "members"
    field :avatar_crest, :string
    field :avatar_image, :string
    embeds_one :preferences, MlAccounts.Preferences, on_replace: :update, defaults_to_struct: true

    # accueil guidé : `pending` = proposé après la connexion ; `completed` et `skipped` ne le sont plus
    # (une relance depuis les paramètres le remet à `pending`)
    field :onboarding_status, :string, default: "pending"
    field :onboarding_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @onboarding_statuses ~w(pending completed skipped)

  def onboarding_statuses, do: @onboarding_statuses

  @doc "État de l'accueil guidé : terminé, passé, ou de nouveau proposé (relancé depuis les paramètres)."
  def onboarding_changeset(user, status) do
    user
    |> change(
      onboarding_status: status,
      onboarding_at: if(status in ~w(completed skipped), do: DateTime.utc_now(:second))
    )
    |> validate_inclusion(:onboarding_status, @onboarding_statuses)
  end

  @interests ~w(astronomy alchemy botany mathematics coding logic history languages mythology writing art music)
  @covers ~w(forest observatory alchemy archive)
  @crests ~w(moon star flame leaf key book)
  @visibilities ~w(public members friends private)
  @max_interests 6

  def interests, do: @interests
  def crests, do: @crests
  def visibilities, do: @visibilities

  @doc "Valide une inscription ; `role` et `confirmed_at` ne sont jamais acceptés en entrée."
  def registration_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:email, :username, :password, :display_name])
    |> update_change(:email, &normalize/1)
    |> update_change(:username, &normalize/1)
    |> validate_required([:email, :username, :password])
    |> validate_email()
    |> validate_format(:username, ~r/^[a-z0-9_]{3,24}$/,
      message: "must be 3-24 characters: lowercase letters, digits or underscore"
    )
    # réservé aux comptes supprimés (pseudonyme `deleted_<id>` posé par l'anonymisation)
    |> validate_format(:username, ~r/^(?!deleted_)/, message: "is reserved")
    |> unsafe_validate_unique(:username, MlAccounts.Repo)
    |> unique_constraint(:username)
    |> validate_profile()
    |> validate_password()
  end

  @doc "Nouvelle adresse (changement vérifié par e-mail) : règles de l'inscription, différente de l'actuelle."
  def email_changeset(user, attrs) do
    changeset =
      user
      |> cast(attrs, [:email])
      # une adresse vide devient nil (changement depuis l'adresse actuelle) : rien à normaliser
      |> update_change(:email, &(&1 && normalize(&1)))
      |> validate_required([:email])
      |> validate_email()

    # `put_change` retire une valeur identique à l'actuelle (ex. même adresse en majuscules)
    if changeset.valid? and not Map.has_key?(changeset.changes, :email),
      do: add_error(changeset, :email, "did not change"),
      else: changeset
  end

  @doc """
  Profil modifiable par l'utilisateur : nom affiché et bio, pronoms (≤ 40, sans caractère de contrôle), centres
  d'intérêt (liste fixe, 6 au plus, doublons retirés), couverture préréglée, visibilité du profil.
  """
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name, :bio, :pronouns, :interests, :cover, :profile_visibility])
    |> validate_profile()
    |> update_change(:pronouns, &trim/1)
    |> validate_length(:pronouns, max: 40)
    |> validate_format(:pronouns, ~r/^[^\p{Cc}\x{202A}-\x{202E}\x{2066}-\x{2069}]*$/u,
      message: "must not contain control characters"
    )
    |> update_change(:interests, &Enum.uniq(&1 || []))
    |> validate_subset(:interests, @interests)
    |> validate_length(:interests, max: @max_interests)
    |> validate_inclusion(:cover, @covers)
    |> validate_required([:profile_visibility])
    |> validate_inclusion(:profile_visibility, @visibilities)
  end

  @doc "Blason préréglé choisi (remplace une image téléversée : le fichier est supprimé après l'écriture)."
  def crest_changeset(user, crest) do
    user
    |> change(avatar_crest: crest, avatar_image: nil)
    |> validate_required([:avatar_crest])
    |> validate_inclusion(:avatar_crest, @crests)
  end

  def password_changeset(user, attrs) do
    user |> cast(attrs, [:password]) |> validate_password()
  end

  def confirm_changeset(user), do: change(user, confirmed_at: DateTime.utc_now(:second))

  @doc "Vérifie un mot de passe en temps constant, y compris sans utilisateur."
  def valid_password?(%__MODULE__{hashed_password: hash}, password)
      when is_binary(hash) and is_binary(password) and password != "" do
    Bcrypt.verify_pass(password, hash)
  end

  def valid_password?(_, _), do: Bcrypt.no_user_verify()

  def normalize(value), do: value |> String.trim() |> String.downcase()

  defp validate_email(changeset) do
    changeset
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_length(:email, max: 160)
    # réservé aux comptes supprimés (adresse `deleted-<id>@deleted.invalid` posée par l'anonymisation)
    |> validate_format(:email, ~r/(?<!@deleted\.invalid)$/, message: "is reserved")
    |> unsafe_validate_unique(:email, MlAccounts.Repo)
    |> unique_constraint(:email)
  end

  # `cast` change déjà une chaîne vide (ou d'espaces) en nil.
  defp trim(nil), do: nil
  defp trim(value), do: String.trim(value)

  # Un nom affiché vide retombe sur le pseudonyme : il n'est jamais nul. Une bio vide est effacée.
  defp validate_profile(changeset) do
    changeset =
      changeset
      |> update_change(:display_name, &trim/1)
      |> update_change(:bio, &trim/1)

    changeset
    |> put_change(
      :display_name,
      get_field(changeset, :display_name) || get_field(changeset, :username)
    )
    |> validate_length(:display_name, max: 60)
    |> validate_length(:bio, max: 500)
  end

  # bcrypt ignore tout ce qui dépasse 72 octets : on le refuse plutôt que de le tronquer en silence.
  defp validate_password(changeset) do
    changeset =
      changeset
      |> validate_required([:password])
      |> validate_length(:password, min: 12)
      |> validate_length(:password, max: 72, count: :bytes)

    case changeset do
      %{valid?: true, changes: %{password: password}} ->
        changeset
        |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)

      _ ->
        changeset
    end
  end
end
