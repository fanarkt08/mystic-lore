defmodule MlStudio.Privacy do
  @moduledoc """
  Export and deletion of a member's studio data. Open AI reservations are settled at billing before anything
  is deleted.
  """
  import Ecto.Query
  alias MlStudio.{AI, Events, Images, Projects, Repo, View}
  alias MlStudio.AI.{Generation, Setting}
  alias MlStudio.Images.Image
  alias MlStudio.Projects.{Collaborator, Project, Version}

  def export(me) do
    owned = Repo.all(from p in Project, where: p.owner_id == ^me, order_by: [p.inserted_at, p.id])

    %{
      "ai_settings" => %{"share_drafts_with_ai" => AI.consent?(me)},
      "projects" =>
        for p <- owned do
          versions =
            Repo.all(from v in Version, where: v.project_id == ^p.id, order_by: v.number)

          p
          |> Projects.load()
          |> View.project("owner")
          |> Map.put("versions", Enum.map(versions, &View.version/1))
        end,
      "collaborations" =>
        Repo.all(
          from c in Collaborator,
            join: p in Project,
            on: p.id == c.project_id,
            where: c.user_id == ^me,
            order_by: [c.inserted_at, c.id],
            select: %{
              "project_id" => p.id,
              "title" => p.title,
              "role" => c.role,
              "since" => c.inserted_at
            }
        ),
      "generations" =>
        Repo.all(from g in Generation, where: g.user_id == ^me, order_by: [g.inserted_at, g.id])
        |> Enum.map(&View.generation/1),
      "images_uploaded" =>
        Repo.all(
          from i in Image,
            where: i.uploader_id == ^me,
            order_by: [i.inserted_at, i.id],
            select: %{
              "id" => i.id,
              "project_id" => i.project_id,
              "alt" => i.alt,
              "content_type" => i.content_type,
              "byte_size" => i.byte_size,
              "inserted_at" => i.inserted_at
            }
        ),
      "media_uploaded" =>
        Repo.all(
          from m in MlStudio.Media.Medium,
            where: m.uploader_id == ^me,
            order_by: [m.inserted_at, m.id],
            select: %{
              "id" => m.id,
              "project_id" => m.project_id,
              "kind" => m.kind,
              "content_type" => m.content_type,
              "byte_size" => m.byte_size,
              "lang" => m.lang,
              "inserted_at" => m.inserted_at
            }
        )
    }
  end

  @doc "`:ok`, or `{:error, :credits_unavailable}` with nothing deleted yet (retry later)."
  def delete(me) do
    with :ok <- settle_credits(me) do
      {:ok, {deleted, kept}} =
        Repo.transact(fn ->
          owned = Repo.all(from p in Project, where: p.owner_id == ^me, lock: "FOR UPDATE")
          ids = Enum.map(owned, & &1.id)

          shared =
            Repo.all(
              from c in Collaborator,
                where: c.project_id in ^ids,
                distinct: true,
                select: c.project_id
            )

          {kept, deleted} =
            Enum.split_with(owned, &(&1.id in shared or not is_nil(&1.published_slug)))

          deleted = Enum.map(deleted, & &1.id)
          Repo.delete_all(from p in Project, where: p.id in ^deleted)

          Repo.update_all(from(p in Project, where: p.id in ^Enum.map(kept, & &1.id)),
            set: [owner_id: nil, updated_at: DateTime.utc_now(:second)]
          )

          Repo.delete_all(from c in Collaborator, where: c.user_id == ^me)
          Repo.delete_all(from g in Generation, where: g.user_id == ^me)
          Repo.delete_all(from s in Setting, where: s.user_id == ^me)
          {:ok, {deleted, kept}}
        end)

      Enum.each(deleted, &Images.remove_files/1)
      # collaborators' open editors reload (the owner is gone)
      Enum.each(kept, &Events.project_changed(&1, nil))
      :ok
    end
  end

  # Every reservation of the member ends exactly once before their generations are deleted.
  defp settle_credits(me) do
    now = DateTime.utc_now(:second)

    {_, cancelled} =
      Repo.update_all(
        from(g in Generation,
          where: g.user_id == ^me and g.status in ["pending", "running"],
          select: g.id
        ),
        set: [status: "cancelled", finished_at: now, updated_at: now]
      )

    for id <- cancelled do
      Oban.cancel_all_jobs(
        from j in Oban.Job,
          where: j.worker == "MlStudio.AI.GenerationWorker" and j.args["generation_id"] == ^id
      )
    end

    Repo.all(from g in Generation, where: g.user_id == ^me and g.credits == "reserved")
    |> Enum.reduce_while(:ok, fn generation, :ok ->
      case AI.settle(generation) do
        {:error, _unavailable} -> {:halt, {:error, :credits_unavailable}}
        # settled, or no reservation at billing
        _ -> {:cont, :ok}
      end
    end)
  end
end
