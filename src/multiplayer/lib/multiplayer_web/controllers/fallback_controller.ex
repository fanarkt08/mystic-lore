defmodule MlMultiplayerWeb.FallbackController do
  @moduledoc "Traduit les erreurs des contextes au format du contrat : `{\"error\": code}` (+ `errors` en 422)."
  use MlMultiplayerWeb, :controller

  @forbidden ~w(forbidden banned blocked not_friends not_participant lobby_invites_closed)a
  @conflict ~w(full too_many_lobbies too_many_links in_progress not_yet not_enough_ready already_member
               not_your_turn finished no_match conflict)a
  @gone ~w(expired revoked exhausted closed)a

  def call(conn, {:error, %Ecto.Changeset{} = changeset}),
    do: invalid(conn, Ecto.Changeset.traverse_errors(changeset, &interpolate/1))

  def call(conn, {:error, {:invalid, errors}}), do: invalid(conn, errors)

  def call(conn, {:error, :invalid_sequence}),
    do: invalid(conn, %{sequence: ["must be 5 runes numbered 0 to 7"]})

  def call(conn, {:error, :duplicate_runes}),
    do: invalid(conn, %{sequence: ["must not repeat a rune"]})

  def call(conn, {:error, {:restricted, until}}),
    do: conn |> put_status(403) |> json(%{error: "restricted", restricted_until: until})

  def call(conn, {:error, code}) when is_atom(code),
    do: conn |> put_status(status(code)) |> json(%{error: code})

  defp invalid(conn, errors),
    do: conn |> put_status(422) |> json(%{error: "invalid", errors: errors})

  defp status(:not_found), do: 404
  defp status(code) when code in @forbidden, do: 403
  defp status(code) when code in @conflict, do: 409
  defp status(code) when code in @gone, do: 410
  defp status(:rate_limited), do: 429

  defp status(code) when code in [:social_unavailable, :accounts_unavailable, :roles_unavailable],
    do: 503

  defp interpolate({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
