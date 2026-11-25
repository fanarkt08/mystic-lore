defmodule MlBillingWeb.FallbackController do
  @moduledoc "Errors of the contract: `{\"error\": code}` (+ `errors` for 422)."
  use MlBillingWeb, :controller

  @statuses %{
    not_found: 404,
    forbidden: 403,
    already_subscribed: 409,
    already_consumed: 409,
    already_released: 409,
    checkout_completed: 409,
    checkout_expired: 409,
    provider_error: 502,
    payments_disabled: 503,
    roles_unavailable: 503,
    audit_unavailable: 503
  }

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    conn |> put_status(422) |> json(%{error: "invalid", errors: errors})
  end

  def call(conn, {:error, {:invalid, errors}}),
    do: conn |> put_status(422) |> json(%{error: "invalid", errors: errors})

  def call(conn, {:error, {:insufficient_credits, balance}}),
    do: conn |> put_status(402) |> json(%{error: "insufficient_credits", balance: balance})

  def call(conn, {:error, code}) when is_map_key(@statuses, code),
    do: conn |> put_status(@statuses[code]) |> json(%{error: code})
end
