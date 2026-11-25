defmodule MlAccountsWeb.SupportController do
  @moduledoc "Demandes de support des visiteurs et des membres, et routes du staff."
  use MlAccountsWeb, :controller
  alias MlAccounts.{Staff, Support}
  alias MlAccountsWeb.SupportJSON

  def create(conn, params) do
    with {:ok, requester} <- requester(conn.assigns[:user_id]),
         {:ok, request, acknowledgement} <- Support.create(requester, params) do
      conn |> put_status(201) |> json(SupportJSON.created(request, acknowledgement))
    end
  end

  # visiteur : aucun membre dans le jeton ; membre : actif et confirmé (une session l'exige déjà)
  defp requester(nil), do: {:ok, nil}

  defp requester(user_id) do
    case MlAccounts.get_user(user_id) do
      %MlAccounts.User{confirmed_at: %DateTime{}} = user ->
        if MlAccounts.Privacy.deleting?(user), do: {:error, :unauthorized}, else: {:ok, user}

      _ ->
        {:error, :unauthorized}
    end
  end

  def mine(conn, _params) do
    requests = Support.mine(conn.assigns.current_user)
    json(conn, %{requests: Enum.map(requests, &SupportJSON.own/1)})
  end

  ## Staff

  def index(conn, params) do
    viewer = conn.assigns.current_user
    page = Support.list(viewer, params)

    json(conn, %{
      entries:
        Enum.map(
          page.entries,
          &SupportJSON.entry(&1, viewer, page.users, page.replies[&1.id] || 0)
        ),
      page: page.page,
      total: page.total,
      total_pages: page.total_pages
    })
  end

  def show(conn, %{"id" => id}) do
    viewer = conn.assigns.current_user
    with {:ok, request} <- Support.detail(viewer, id), do: render_detail(conn, request)
  end

  def reply(conn, %{"id" => id} = params) do
    with {:ok, request, _reply} <- Support.reply(conn.assigns.current_user, id, params),
         do: conn |> put_status(201) |> render_detail(request)
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, request} <- Support.update(conn.assigns.current_user, id, params),
         do: render_detail(conn, request)
  end

  @doc "Admin seulement (pipeline `:admin`) : la demande et ses réponses sont effacées, l'effacement est audité."
  def delete(conn, %{"id" => id}) do
    with {:ok, _request} <- Support.delete(conn.assigns.current_user, id),
         do: send_resp(conn, 204, "")
  end

  defp render_detail(conn, request) do
    viewer = conn.assigns.current_user
    people = Staff.people(Enum.map(request.replies, & &1.author_id))

    json(conn, %{
      request: SupportJSON.detail(request, viewer, Support.users([request]), people)
    })
  end
end
