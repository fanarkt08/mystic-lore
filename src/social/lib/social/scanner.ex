defmodule MlSocial.Scanner do
  @moduledoc """
  Analyse antivirus des pièces jointes avant tout stockage. Un antivirus injoignable fait refuser le fichier.
  """
  require Logger

  @callback scan(binary(), keyword()) :: :clean | {:infected, String.t()} | {:error, term()}

  @doc "`{:ok, \"clean\" | \"unscanned\"}`, `{:error, :infected}` ou `{:error, :scanner_unavailable}`."
  def check(bytes) do
    case Application.get_env(:social, :scanner) do
      nil ->
        {:ok, "unscanned"}

      {adapter, opts} ->
        case adapter.scan(bytes, opts) do
          :clean ->
            {:ok, "clean"}

          {:infected, signature} ->
            Logger.warning("attachment refused by the antivirus: #{signature}")
            {:error, :infected}

          {:error, reason} ->
            Logger.error("antivirus unavailable, attachment refused: #{inspect(reason)}")
            {:error, :scanner_unavailable}
        end
    end
  end
end
