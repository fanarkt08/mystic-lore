defmodule MlSocialWeb.FallbackController do
  @moduledoc "Traduit les erreurs des contextes au format du contrat : `{\"error\": code}` (+ `errors` en 422)."
  use MlSocialWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}),
    do: invalid(conn, Ecto.Changeset.traverse_errors(changeset, &interpolate/1))

  def call(conn, {:error, {:invalid, errors}}), do: invalid(conn, errors)

  def call(conn, {:error, {:restricted, until}}),
    do: conn |> put_status(403) |> json(%{error: "restricted", restricted_until: until})

  # un membre refusé lors d'un ajout en groupe : le code et le membre en cause
  def call(conn, {:error, {:refused, code, user_id}}),
    do: conn |> put_status(403) |> json(%{error: code, user_id: user_id})

  def call(conn, {:error, {:rate_limited, seconds}}) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_status(429)
    |> json(%{error: "rate_limited", retry_after: seconds})
  end

  def call(conn, {:error, code}) when is_atom(code),
    do: conn |> put_status(status(code)) |> json(%{error: code})

  defp invalid(conn, errors),
    do: conn |> put_status(422) |> json(%{error: "invalid", errors: errors})

  defp status(:not_found), do: 404
  defp status(:self), do: 422

  defp status(code)
       when code in [:blocked, :not_friends, :forbidden, :not_owner] or
              code in [:friend_requests_closed, :group_adds_closed, :lobby_invites_closed],
       do: 403

  defp status(code) when code in [:already_friends, :already_requested, :already_resolved],
    do: 409

  defp status(code) when code in [:no_evidence, :no_attachment, :staff_target], do: 409
  defp status(code) when code in [:already_member, :group_full], do: 409

  defp status(code)
       when code in [:roles_unavailable, :accounts_unavailable, :audit_unavailable] or
              code == :scanner_unavailable,
       do: 503

  defp interpolate({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
