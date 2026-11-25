defmodule MlStudioWeb.ContentController do
  @moduledoc "Modules and lessons (autosave with `lock_version`, keyboard reordering)."
  use MlStudioWeb, :controller
  alias MlStudio.Projects

  def create_module(conn, %{"id" => id} = params) do
    with {:ok, module} <- Projects.add_module(conn.assigns.user_id, id, params),
         do: conn |> put_status(201) |> json(%{module: View.module(%{module | lessons: []})})
  end

  def update_module(conn, %{"id" => id, "module_id" => module_id} = params) do
    with {:ok, module} <- Projects.update_module(conn.assigns.user_id, id, module_id, params),
         do: json(conn, %{module: View.module(module)})
  end

  def delete_module(conn, %{"id" => id, "module_id" => module_id}) do
    with {:ok, _} <- Projects.delete_module(conn.assigns.user_id, id, module_id),
         do: send_resp(conn, 204, "")
  end

  def order_modules(conn, %{"id" => id} = params) do
    with {:ok, modules} <-
           Projects.reorder_modules(conn.assigns.user_id, id, params["module_ids"]),
         do: json(conn, %{modules: Enum.map(modules, &View.module/1)})
  end

  def create_lesson(conn, %{"id" => id, "module_id" => module_id} = params) do
    with {:ok, lesson} <- Projects.add_lesson(conn.assigns.user_id, id, module_id, params),
         do: conn |> put_status(201) |> json(%{lesson: View.lesson(lesson)})
  end

  def update_lesson(conn, %{"id" => id, "lesson_id" => lesson_id} = params) do
    with {:ok, lesson} <- Projects.update_lesson(conn.assigns.user_id, id, lesson_id, params),
         do: json(conn, %{lesson: View.lesson(lesson)})
  end

  def delete_lesson(conn, %{"id" => id, "lesson_id" => lesson_id}) do
    with {:ok, _} <- Projects.delete_lesson(conn.assigns.user_id, id, lesson_id),
         do: send_resp(conn, 204, "")
  end

  def order_lessons(conn, %{"id" => id, "module_id" => module_id} = params) do
    with {:ok, lessons} <-
           Projects.reorder_lessons(conn.assigns.user_id, id, module_id, params["lesson_ids"]),
         do: json(conn, %{lessons: Enum.map(lessons, &View.lesson/1)})
  end
end
