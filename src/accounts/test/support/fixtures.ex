defmodule MlAccounts.Fixtures do
  @moduledoc "Données de test."
  alias MlAccounts.{Repo, User}

  def password, do: "correct horse battery staple"

  @doc "Membre inséré directement (aucun e-mail envoyé) ; confirmé sauf `confirmed: false`."
  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {confirmed?, attrs} = attrs |> Map.new() |> Map.pop(:confirmed, true)

    %{email: "member#{n}@example.test", username: "member_#{n}", password: password()}
    |> Map.merge(attrs)
    |> User.registration_changeset()
    |> Ecto.Changeset.put_change(:confirmed_at, if(confirmed?, do: DateTime.utc_now(:second)))
    |> Repo.insert!()
  end

  @doc "Ouvre une session pour un membre confirmé et renvoie son jeton."
  def session_fixture(user, client \\ %{}) do
    {:ok, token, _user} = MlAccounts.login(user.email, password(), client)
    token
  end

  @doc "Active la 2FA avec un code du pas précédent et renvoie le membre, le secret et les codes de récupération."
  def two_factor_fixture(user) do
    now = System.os_time(:second)
    {:ok, %{secret: encoded}} = MlAccounts.TwoFactor.setup(user, password())
    secret = Base.decode32!(encoded, padding: false)
    {:ok, codes} = MlAccounts.TwoFactor.enable(Repo.reload!(user), totp(secret, now - 30), now)
    {Repo.reload!(user), secret, codes}
  end

  @doc "Code TOTP d'un secret brut à l'instant `time` (secondes Unix)."
  def totp(secret, time \\ System.os_time(:second)),
    do: NimbleTOTP.verification_code(secret, time: time)

  @doc "Challenge de connexion d'un membre dont la 2FA est active."
  def challenge_fixture(user) do
    {:two_factor, challenge, _user} = MlAccounts.login(user.email, password())
    challenge
  end
end
