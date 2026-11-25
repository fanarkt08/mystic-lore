defmodule MlAccountsWeb.SanctionController do
  @moduledoc "Sanctions et appels, côté staff et côté membre."
  use MlAccountsWeb, :controller
  alias MlAccounts.{Sanctions, Staff}
  alias MlAccountsWeb.AdminJSON

  def create(conn, %{"id" => id} = params) do
    with {:ok, sanction, outcome} <- Sanctions.issue(conn.assigns.current_user, id, params) do
      conn
      |> put_status(if(outcome == :created, do: 201, else: 200))
      |> json(%{sanction: sanction_json(sanction), replayed: outcome == :replayed})
    end
  end

  def lift(conn, %{"id" => id} = params) do
    with {:ok, sanction} <- Sanctions.lift(conn.assigns.current_user, id, params),
         do: json(conn, %{sanction: sanction_json(sanction)})
  end

  def appeals(conn, params) do
    page = Sanctions.list_appeals(params)

    people =
      Staff.people(
        Enum.flat_map(
          page.entries,
          &[&1.decided_by, &1.sanction.issued_by, &1.sanction.lifted_by]
        )
      )

    json(conn, %{page | entries: Enum.map(page.entries, &AdminJSON.queued_appeal(&1, people))})
  end

  def decide(conn, %{"id" => id} = params) do
    with {:ok, appeal} <- Sanctions.decide(conn.assigns.current_user, id, params) do
      people = Staff.people([appeal.decided_by])
      json(conn, %{appeal: AdminJSON.appeal(appeal, people)})
    end
  end

  def mine(conn, _params) do
    sanctions = Sanctions.for_user(conn.assigns.current_user.id)
    json(conn, %{sanctions: Enum.map(sanctions, &AdminJSON.own_sanction/1)})
  end

  def appeal(conn, %{"id" => id} = params) do
    with {:ok, appeal} <- Sanctions.appeal(conn.assigns.current_user, id, params) do
      conn |> put_status(201) |> json(%{appeal: AdminJSON.appeal(appeal, %{})})
    end
  end

  defp sanction_json(sanction) do
    sanction = %{sanction | appeals: []}
    AdminJSON.sanction(sanction, Staff.people([sanction.issued_by, sanction.lifted_by]))
  end
end
