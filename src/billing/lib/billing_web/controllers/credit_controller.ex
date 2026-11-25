defmodule MlBillingWeb.CreditController do
  @moduledoc "AI credits: reservations by the studio on behalf of a user, and the user's own balance."
  use MlBillingWeb, :controller
  alias MlBilling.Credits

  # Services allowed to spend credits on behalf of users (internal token `svc`).
  @callers ["studio"]

  action_fallback MlBillingWeb.FallbackController

  plug :allowed_caller when action in [:reserve, :consume, :release]

  def me(conn, params) do
    page =
      case Integer.parse(to_string(params["page"] || "1")) do
        {n, ""} when n > 0 -> n
        _ -> 1
      end

    %{account: account} = overview = Credits.overview(conn.assigns.user_id, page)

    json(conn, %{
      balance: account.balance,
      reserved: account.reserved,
      allocation: account.allocation,
      plan: account.plan,
      period: account.period,
      resets_at: overview.resets_at,
      entries: Enum.map(overview.entries, &entry/1),
      page: overview.page,
      total_pages: overview.total_pages,
      total: overview.total
    })
  end

  def reserve(conn, params) do
    with {:ok, p} <- Credits.params(params, conn.assigns.caller, [:user_id, :amount, :ref]),
         {:ok, reply} <- Credits.reserve(p.user_id, p.amount, p.ref, p[:reason]),
         do: json(conn, reply)
  end

  def consume(conn, params) do
    with {:ok, p} <- Credits.params(params, conn.assigns.caller, [:user_id, :ref]),
         {:ok, reply} <- Credits.consume(p.user_id, p.ref),
         do: json(conn, reply)
  end

  def release(conn, params) do
    with {:ok, p} <- Credits.params(params, conn.assigns.caller, [:user_id, :ref]),
         {:ok, reply} <- Credits.release(p.user_id, p.ref),
         do: json(conn, reply)
  end

  defp entry(e),
    do:
      Map.take(e, [
        :id,
        :kind,
        :amount,
        :delta,
        :balance_after,
        :ref,
        :reason,
        :period,
        :inserted_at
      ])

  defp allowed_caller(conn, _opts) do
    if conn.assigns.caller in @callers,
      do: conn,
      else: conn |> put_status(403) |> json(%{error: "forbidden"}) |> halt()
  end
end
