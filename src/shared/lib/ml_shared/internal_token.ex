defmodule MlShared.InternalToken do
  @moduledoc """
  Jeton signé, valable 5 minutes, qui authentifie un appel entre services et porte l'utilisateur éventuel.
  `INTERNAL_SECRET` n'est jamais envoyé au navigateur.
  """
  @salt "ml-internal-v1"
  @max_age 300

  @min_bytes 32

  @doc "Renvoie le secret partagé et lève une erreur s'il manque ou fait moins de 32 octets."
  def secret do
    case Application.get_env(:ml_shared, :internal_secret) || System.get_env("INTERNAL_SECRET") do
      s when is_binary(s) and byte_size(s) >= @min_bytes -> s
      _ -> raise "INTERNAL_SECRET is missing or too short (at least #{@min_bytes} bytes required)"
    end
  end

  def sign(service, user_id \\ nil) when is_binary(service) do
    Plug.Crypto.sign(secret(), @salt, %{"svc" => service, "sub" => user_id})
  end

  def verify(token) when is_binary(token) do
    case Plug.Crypto.verify(secret(), @salt, token, max_age: @max_age) do
      {:ok, %{"svc" => svc} = data} when is_binary(svc) -> {:ok, data}
      _ -> {:error, :invalid}
    end
  end

  def verify(_), do: {:error, :invalid}
end
