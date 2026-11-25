defmodule MlAccounts.TwoFactor do
  @moduledoc """
  Authentification à deux facteurs TOTP, avec des codes de récupération à usage unique.
  Le secret est chiffré au repos ; changer `TOTP_ENCRYPTION_KEY` rend les secrets existants illisibles.
  """
  import Ecto.Query
  alias MlAccounts.{LoginChallenge, RecoveryCode, Repo, Throttle, User}

  @issuer "MysticLore"
  @period 30
  @max_failures 5
  @failure_window_minutes 15
  @recovery_codes 10
  # base32 de Crockford (sans i, l, o, u : pas de confusion avec 1 et 0)
  @alphabet "0123456789abcdefghjkmnpqrstvwxyz"

  def status(%User{} = user) do
    %{
      enabled: enabled?(user),
      enabled_at: user.totp_enabled_at,
      recovery_codes_left:
        Repo.aggregate(from(r in RecoveryCode, where: r.user_id == ^user.id), :count)
    }
  end

  def enabled?(%User{totp_secret: secret}), do: is_binary(secret)

  @doc "Prépare un nouveau secret en attente, activé seulement par un premier code valide."
  def setup(%User{} = user, password) do
    with :ok <- check(not enabled?(user), :already_enabled),
         :ok <- MlAccounts.verify_password(user, password) do
      secret = NimbleTOTP.secret()

      Repo.update_all(where(User, id: ^user.id),
        set: [totp_pending_secret: encrypt(secret, user.id)]
      )

      uri = NimbleTOTP.otpauth_uri("#{@issuer}:#{user.email}", secret, issuer: @issuer)

      {:ok,
       %{
         secret: Base.encode32(secret, padding: false),
         otpauth_uri: uri,
         qr_svg: uri |> EQRCode.encode() |> EQRCode.svg(width: 232, viewbox: true)
       }}
    end
  end

  @doc "Active la 2FA avec un code du secret en attente ; renvoie les 10 codes de récupération (en clair, une fois)."
  def enable(%User{} = user, code, now \\ System.os_time(:second)) do
    with :ok <- check(not enabled?(user), :already_enabled),
         :ok <- check(is_binary(user.totp_pending_secret), :setup_required),
         :ok <- reserve_attempt(user),
         {:ok, secret} <- decrypt(user.totp_pending_secret, user.id),
         step when is_integer(step) <- matching_step(secret, totp_code(code), nil, now) do
      Throttle.clear(throttle_key(user))

      with {:ok, codes} <- activate(user, step) do
        MlAccounts.Notify.security(user.id, "two_factor_enabled")
        {:ok, codes}
      end
    else
      {:error, reason} when reason in [:already_enabled, :setup_required, :locked] ->
        {:error, reason}

      _ ->
        {:error, :invalid_code}
    end
  end

  # Verrou sur la ligne : une configuration relancée ou une activation concurrente ne passe pas inaperçue.
  defp activate(%User{id: id, totp_pending_secret: pending} = user, step) do
    Repo.transact(fn ->
      case Repo.one(from u in User, where: u.id == ^id, lock: "FOR UPDATE") do
        %User{totp_secret: nil, totp_pending_secret: ^pending} ->
          Repo.update_all(where(User, id: ^id),
            set: [
              totp_secret: pending,
              totp_pending_secret: nil,
              totp_last_step: step,
              totp_enabled_at: DateTime.utc_now(:second)
            ]
          )

          {:ok, replace_recovery_codes(user)}

        %User{totp_secret: nil} ->
          {:error, :setup_required}

        _ ->
          {:error, :already_enabled}
      end
    end)
  end

  @doc "Désactive la 2FA (mot de passe et code exigés) ; supprime les codes de récupération et les challenges."
  def disable(%User{} = user, password, code) do
    with :ok <- check(enabled?(user), :not_enabled),
         :ok <- MlAccounts.verify_password(user, password),
         :ok <- verify(user, code) do
      Repo.transact(fn ->
        Repo.update_all(where(User, id: ^user.id),
          set: [
            totp_secret: nil,
            totp_pending_secret: nil,
            totp_last_step: nil,
            totp_enabled_at: nil
          ]
        )

        Repo.delete_all(from r in RecoveryCode, where: r.user_id == ^user.id)
        Repo.delete_all(from c in LoginChallenge, where: c.user_id == ^user.id)
        {:ok, nil}
      end)

      MlAccounts.Notify.security(user.id, "two_factor_disabled")
    end
  end

  @doc "Remplace les codes de récupération (mot de passe exigé) ; les anciens ne fonctionnent plus."
  def regenerate_recovery_codes(%User{} = user, password) do
    with :ok <- check(enabled?(user), :not_enabled),
         :ok <- MlAccounts.verify_password(user, password) do
      codes = replace_recovery_codes(user)
      MlAccounts.Notify.security(user.id, "recovery_codes_regenerated")
      {:ok, codes}
    end
  end

  @doc """
  Vérifie un second facteur : 6 chiffres pour un code TOTP (qui consomme son pas de temps), sinon un code
  de récupération (consommé).
  """
  def verify(user, code, now \\ System.os_time(:second))

  def verify(%User{totp_secret: secret} = user, code, now) when is_binary(secret) do
    with :ok <- reserve_attempt(user) do
      code = if is_binary(code), do: String.replace(code, ~r/[\s-]/, ""), else: ""

      if consume(user, code, now) do
        Throttle.clear(throttle_key(user))
      else
        {:error, :invalid_code}
      end
    end
  end

  def verify(%User{}, _code, _now), do: {:error, :invalid_code}

  defp consume(user, code, now) do
    if code =~ ~r/^\d{6}$/,
      do: consume_totp(user, code, now),
      else: consume_recovery_code(user, code)
  end

  # Le pas accepté doit dépasser le dernier enregistré en base : deux requêtes concurrentes portant le même
  # code ne passent pas toutes les deux.
  defp consume_totp(user, code, now) do
    with {:ok, secret} <- decrypt(user.totp_secret, user.id),
         step when is_integer(step) <- matching_step(secret, code, user.totp_last_step, now),
         {1, _} <-
           Repo.update_all(
             from(u in User,
               where: u.id == ^user.id,
               where: is_nil(u.totp_last_step) or u.totp_last_step < ^step
             ),
             set: [totp_last_step: step]
           ) do
      true
    else
      _ -> false
    end
  end

  defp consume_recovery_code(user, code) do
    query =
      from r in RecoveryCode,
        where: r.user_id == ^user.id and r.code_hash == ^recovery_hash(user.id, code)

    match?({1, _}, Repo.delete_all(query))
  end

  @doc false
  # Accepte le pas courant ±1 s'il suit `last_step` ; la comparaison se fait en temps constant.
  def matching_step(secret, code, last_step, now) do
    current = div(now, @period)

    Enum.find((current - 1)..(current + 1), fn step ->
      step > (last_step || -1) and NimbleTOTP.valid?(secret, code, time: step * @period)
    end)
  end

  defp totp_code(code) when is_binary(code), do: String.replace(code, ~r/\s/, "")
  defp totp_code(_), do: ""

  defp reserve_attempt(user),
    do: Throttle.reserve(throttle_key(user), @max_failures, @failure_window_minutes)

  defp throttle_key(user), do: "totp:" <> user.id

  defp check(true, _error), do: :ok
  defp check(false, error), do: {:error, error}

  ## Codes de récupération

  defp replace_recovery_codes(user) do
    codes = for _ <- 1..@recovery_codes, do: random_code()
    now = DateTime.utc_now(:second)

    rows =
      for code <- codes,
          do: %{user_id: user.id, code_hash: recovery_hash(user.id, code), inserted_at: now}

    Repo.transact(fn ->
      Repo.delete_all(from r in RecoveryCode, where: r.user_id == ^user.id)
      Repo.insert_all(RecoveryCode, rows)
      {:ok, Enum.map(codes, &format_code/1)}
    end)
    |> elem(1)
  end

  # 10 octets aléatoires = 16 caractères de 5 bits (80 bits : un SHA-256 suffit, aucune attaque hors ligne réaliste).
  defp random_code do
    for <<c::5 <- :crypto.strong_rand_bytes(10)>>, into: "", do: <<:binary.at(@alphabet, c)>>
  end

  defp format_code(code),
    do: code |> String.codepoints() |> Enum.chunk_every(4) |> Enum.map_join("-", &Enum.join/1)

  # Saisie tolérante : casse, espaces et tirets ignorés ; i/l lus comme 1, o comme 0.
  defp recovery_hash(user_id, code) do
    normalized =
      code
      |> String.downcase()
      |> String.replace(~r/[^0-9a-z]/, "")
      |> String.replace(["i", "l"], "1")
      |> String.replace("o", "0")

    :crypto.hash(:sha256, user_id <> ":" <> normalized)
  end

  ## Chiffrement du secret au repos

  defp encrypt(secret, user_id) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, secret, user_id, true)

    <<1, iv::binary, tag::binary, ciphertext::binary>>
  end

  defp decrypt(<<1, iv::binary-12, tag::binary-16, ciphertext::binary>>, user_id) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ciphertext, user_id, tag, false) do
      secret when is_binary(secret) -> {:ok, secret}
      :error -> :error
    end
  end

  defp decrypt(_, _), do: :error

  defp key do
    base =
      case Application.get_env(:accounts, :totp_encryption_key) do
        key when key in [nil, ""] -> MlShared.InternalToken.secret()
        key when byte_size(key) >= 32 -> key
        _ -> raise "TOTP_ENCRYPTION_KEY is too short (at least 32 bytes required)"
      end

    :crypto.mac(:hmac, :sha256, base, "ml-accounts:totp-secret:v1")
  end
end
