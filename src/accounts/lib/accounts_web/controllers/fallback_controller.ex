defmodule MlAccountsWeb.FallbackController do
  @moduledoc "Erreurs des contrôleurs au format du contrat : `{\"error\": code}`, plus `errors` par champ pour 422."
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @statuses %{
    not_found: 404,
    unauthorized: 401,
    invalid_credentials: 401,
    invalid_code: 401,
    unconfirmed: 403,
    forbidden: 403,
    self: 403,
    same_staff: 403,
    staff_target: 409,
    last_admin: 409,
    not_active: 409,
    not_appealable: 409,
    appeal_open: 409,
    already_decided: 409,
    already_resolved: 409,
    # support : répondre à une demande close (la rouvrir d'abord)
    closed: 409,
    conflict: 409,
    account_deleted: 403,
    not_ready: 409,
    deletion_in_progress: 409,
    expired: 410,
    current_session: 409,
    already_enabled: 409,
    not_enabled: 409,
    setup_required: 409,
    locked: 429,
    rate_limited: 429,
    vip_required: 403,
    entitlements_unavailable: 503
  }

  def init(result), do: result

  def call(conn, {:error, %Ecto.Changeset{} = changeset}), do: invalid(conn, errors(changeset))
  def call(conn, {:error, {:invalid, errors}}), do: invalid(conn, errors)

  def call(conn, {:error, code}),
    do: conn |> put_status(Map.fetch!(@statuses, code)) |> json(%{error: code})

  def call(conn, nil), do: call(conn, {:error, :not_found})

  defp invalid(conn, errors),
    do: conn |> put_status(422) |> json(%{error: "invalid", errors: errors})

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
