defmodule MlLearningWeb.AdminController do
  @moduledoc """
  Indicateurs du staff sur les 7 derniers jours ; le rôle est relu chez accounts à chaque appel.
  """
  use MlLearningWeb, :controller
  import Ecto.Query
  alias MlLearning.Progress.{Enrollment, LessonProgress, XpEvent}
  alias MlLearning.Repo

  def stats(conn, _params) do
    case staff(conn.assigns.user_id) do
      :ok ->
        week_ago = DateTime.add(DateTime.utc_now(), -7, :day)

        json(conn, %{
          stats: %{
            enrollments: Repo.aggregate(Enrollment, :count),
            lessons_completed_7d:
              Repo.aggregate(
                from(p in LessonProgress,
                  where: p.status == "completed" and p.completed_at > ^week_ago
                ),
                :count
              ),
            xp_7d:
              Repo.one(
                from(x in XpEvent,
                  where: x.inserted_at > ^week_ago,
                  select: coalesce(sum(x.amount), 0)
                )
              )
          }
        })

      {:error, code, status} ->
        conn |> put_status(status) |> json(%{error: code})
    end
  end

  defp staff(user_id) do
    case MlShared.Client.get(:accounts, "/api/internal/users/:id", path_params: [id: user_id]) do
      {:ok, %{"user" => %{"role" => role}}} when role in ~w(moderator admin) -> :ok
      {:ok, _} -> {:error, :forbidden, 403}
      {:error, {:http, 404, _}} -> {:error, :forbidden, 403}
      _ -> {:error, :roles_unavailable, 503}
    end
  end
end
