defmodule MlBillingWeb.BillingController do
  use MlBillingWeb, :controller

  action_fallback MlBillingWeb.FallbackController

  def health(conn, _params) do
    if db_up?(),
      do: json(conn, %{status: "ok"}),
      else: conn |> put_status(503) |> json(%{status: "unavailable"})
  end

  defp db_up? do
    match?({:ok, _}, MlBilling.Repo.query("SELECT 1"))
  rescue
    _ -> false
  end

  def plans(conn, _params), do: json(conn, %{plans: MlBilling.plans(), mode: MlBilling.mode()})

  def entitlements(conn, %{"user_id" => user_id}) do
    case Ecto.UUID.cast(user_id) do
      {:ok, id} -> json(conn, MlBilling.entitlements(id))
      :error -> {:error, :not_found}
    end
  end

  def me(conn, _params) do
    overview = MlBilling.overview(conn.assigns.user_id)
    json(conn, %{overview | invoices: Enum.map(overview.invoices, &invoice/1)})
  end

  def cancel(conn, _params) do
    with {:ok, entitlements} <- MlBilling.cancel(conn.assigns.user_id),
         do: json(conn, entitlements)
  end

  def resume(conn, _params) do
    with {:ok, entitlements} <- MlBilling.resume(conn.assigns.user_id),
         do: json(conn, entitlements)
  end

  def portal(conn, _params) do
    with {:ok, url} <- MlBilling.portal(conn.assigns.user_id, conn.body_params),
         do: conn |> put_status(201) |> json(%{url: url})
  end

  defp invoice(invoice) do
    Map.take(invoice, [
      :id,
      :amount_cents,
      :currency,
      :status,
      :period_start,
      :period_end,
      :hosted_url
    ])
  end
end
