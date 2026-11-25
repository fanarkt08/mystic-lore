defmodule MlStudioWeb.AIController do
  @moduledoc "AI provider info, consent setting, generations (cost confirmed by the caller)."
  use MlStudioWeb, :controller
  alias MlStudio.AI

  def info(conn, _params), do: json(conn, AI.info(conn.assigns.user_id))

  def settings(conn, _params),
    do: json(conn, %{share_drafts_with_ai: AI.consent?(conn.assigns.user_id)})

  def update_settings(conn, params) do
    with {:ok, value} <- AI.set_consent(conn.assigns.user_id, params),
         do: json(conn, %{share_drafts_with_ai: value})
  end

  def history(conn, params) do
    page =
      case Integer.parse(to_string(params["page"] || "1")) do
        {n, ""} when n > 0 -> n
        _ -> 1
      end

    %{entries: entries} = history = AI.history(conn.assigns.user_id, page)

    json(conn, %{
      entries:
        for({g, title} <- entries, do: Map.put(View.generation(g), "project_title", title)),
      page: history.page,
      total_pages: history.total_pages,
      total: history.total
    })
  end

  def index(conn, %{"id" => id}) do
    with {:ok, generations} <- AI.list(conn.assigns.user_id, id),
         do: json(conn, %{generations: Enum.map(generations, &View.generation/1)})
  end

  def create(conn, %{"id" => id} = params) do
    with {:ok, generation} <- AI.create(conn.assigns.user_id, id, params),
         do: conn |> put_status(202) |> json(%{generation: View.generation(generation)})
  end

  def cancel(conn, %{"id" => id}) do
    with {:ok, generation} <- AI.cancel(conn.assigns.user_id, id),
         do: json(conn, %{generation: View.generation(generation)})
  end

  def retry(conn, %{"id" => id} = params) do
    with {:ok, generation} <- AI.retry(conn.assigns.user_id, id, params),
         do: conn |> put_status(202) |> json(%{generation: View.generation(generation)})
  end

  def apply(conn, %{"id" => id}) do
    with {:ok, generation} <- AI.apply(conn.assigns.user_id, id),
         do: json(conn, %{generation: View.generation(generation)})
  end
end
