defmodule MlCommunityWeb.FallbackController do
  @moduledoc "Traduit les erreurs des contextes au format du contrat : `{\"error\": code}` (+ `errors` en 422)."
  use MlCommunityWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}),
    do: invalid(conn, Ecto.Changeset.traverse_errors(changeset, &interpolate/1))

  def call(conn, {:error, {:invalid, errors}}), do: invalid(conn, errors)

  def call(conn, {:error, {:restricted, until}}),
    do: conn |> put_status(403) |> json(%{error: "restricted", restricted_until: until})

  def call(conn, {:error, code}) when is_atom(code),
    do: conn |> put_status(status(code)) |> json(%{error: code})

  defp invalid(conn, errors),
    do: conn |> put_status(422) |> json(%{error: "invalid", errors: errors})

  defp status(:not_found), do: 404

  defp status(code) when code in [:forbidden, :own_content, :locked, :edit_window_expired],
    do: 403

  defp status(code) when code in [:conflict, :already_reported, :already_resolved], do: 409
  defp status(:rate_limited), do: 429

  defp status(code) when code in [:blocks_unavailable, :roles_unavailable, :audit_unavailable],
    do: 503

  defp interpolate({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
