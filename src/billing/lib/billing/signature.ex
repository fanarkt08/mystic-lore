defmodule MlBilling.Signature do
  @moduledoc "Checks a `Stripe-Signature` header: HMAC-SHA256, at most 300 s old, compared in constant time."
  @tolerance 300

  def header(payload, secret, timestamp \\ System.os_time(:second)),
    do: "t=#{timestamp},v1=#{mac(secret, timestamp, payload)}"

  @doc "`:ok | {:error, :invalid_signature | :expired_signature}`."
  def verify(payload, header, secret, now \\ System.os_time(:second))

  def verify(payload, header, secret, now)
      when is_binary(payload) and is_binary(header) and is_binary(secret) and secret != "" do
    with {:ok, timestamp, candidates} <- parse(header) do
      expected = mac(secret, timestamp, payload)
      valid? = Enum.reduce(candidates, false, &(Plug.Crypto.secure_compare(&1, expected) or &2))

      cond do
        not valid? -> {:error, :invalid_signature}
        abs(now - timestamp) > @tolerance -> {:error, :expired_signature}
        true -> :ok
      end
    end
  end

  def verify(_payload, _header, _secret, _now), do: {:error, :invalid_signature}

  defp mac(secret, timestamp, payload),
    do:
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{payload}")
      |> Base.encode16(case: :lower)

  defp parse(header) do
    pairs =
      for part <- String.split(header, ","), do: String.split(String.trim(part), "=", parts: 2)

    candidates = for ["v1", sig] <- pairs, do: sig

    with [timestamp] <- for(["t", t] <- pairs, do: t),
         {timestamp, ""} <- Integer.parse(timestamp),
         [_ | _] <- candidates do
      {:ok, timestamp, candidates}
    else
      _ -> {:error, :invalid_signature}
    end
  end
end
