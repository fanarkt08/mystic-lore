defmodule MlStudio.View do
  @moduledoc "JSON shapes of the studio, shared by the controllers and the real-time events."
  alias MlStudio.AI.Generation
  alias MlStudio.Images.Image
  alias MlStudio.Media.Medium
  alias MlStudio.Projects.{Collaborator, CourseModule, Lesson, Project, Version}

  @brief ~w(title summary description objectives prerequisites audience level duration_minutes category cover)a

  def summary(%Project{} = p, role, {modules, lessons}) do
    %{
      "id" => p.id,
      "title" => p.title,
      "status" => p.status,
      "role" => role,
      "category" => p.category,
      "cover" => p.cover,
      "level" => p.level,
      "modules_count" => modules,
      "lessons_count" => lessons,
      "published_slug" => p.published_slug,
      "updated_at" => p.updated_at
    }
  end

  @doc "Brief and workflow fields (no content)."
  def brief(%Project{} = p) do
    p
    |> Map.take(@brief)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Map.merge(%{
      "id" => p.id,
      "owner_id" => p.owner_id,
      "status" => p.status,
      "lock_version" => p.lock_version,
      "content_revision" => p.content_revision,
      "review" => review(p),
      "publication" => publication(p),
      "attestations" => attestations(p),
      "submitted_at" => p.submitted_at,
      "inserted_at" => p.inserted_at,
      "updated_at" => p.updated_at
    })
  end

  @doc "Full project (brief + modules + lessons + images + collaborators) for a member."
  def project(%Project{} = p, role) do
    Map.merge(brief(p), %{
      "role" => role,
      "modules" => Enum.map(p.modules, &module/1),
      "images" => Enum.map(p.images, &image/1),
      "media" => Enum.map(p.media, &medium/1),
      "collaborators" => Enum.map(p.collaborators, &collaborator/1)
    })
  end

  def module(%CourseModule{} = m) do
    %{
      "id" => m.id,
      "position" => m.position,
      "title" => m.title,
      "lock_version" => m.lock_version,
      "lessons" =>
        if(Ecto.assoc_loaded?(m.lessons), do: Enum.map(m.lessons, &lesson/1), else: nil)
    }
  end

  def lesson(%Lesson{} = l) do
    %{
      "id" => l.id,
      "module_id" => l.module_id,
      "position" => l.position,
      "title" => l.title,
      "kind" => l.kind,
      "body" => l.body,
      "xp_reward" => l.xp_reward,
      "content" => l.content,
      "lock_version" => l.lock_version,
      "updated_at" => l.updated_at
    }
  end

  def image(%Image{} = i) do
    %{
      "id" => i.id,
      "alt" => i.alt,
      "lesson_id" => i.lesson_id,
      "content_type" => i.content_type,
      "byte_size" => i.byte_size,
      "source" => i.source,
      "inserted_at" => i.inserted_at
    }
  end

  def medium(%Medium{} = m) do
    %{
      "id" => m.id,
      "kind" => m.kind,
      "content_type" => m.content_type,
      "byte_size" => m.byte_size,
      "lang" => m.lang,
      "label" => m.label,
      "inserted_at" => m.inserted_at
    }
  end

  def collaborator(%Collaborator{} = c),
    do: %{"user_id" => c.user_id, "username" => c.username, "role" => c.role}

  def version(%Version{} = v) do
    %{
      "id" => v.id,
      "number" => v.number,
      "note" => v.note,
      "source" => v.source,
      "author_id" => v.author_id,
      "inserted_at" => v.inserted_at
    }
  end

  def generation(%Generation{} = g) do
    %{
      "id" => g.id,
      "project_id" => g.project_id,
      "lesson_id" => g.lesson_id,
      "user_id" => g.user_id,
      "kind" => g.kind,
      "status" => g.status,
      "cost" => g.cost,
      "credits" => g.credits,
      "provider" => g.provider,
      "model" => g.model,
      "demo" => g.provider == "demo",
      "brief" => g.brief,
      "result" => g.result,
      "error" => g.error,
      "retry_of" => g.retry_of,
      "applied_at" => g.applied_at,
      "started_at" => g.started_at,
      "finished_at" => g.finished_at,
      "inserted_at" => g.inserted_at
    }
  end

  defp review(%Project{reviewed_at: nil}), do: nil

  defp review(%Project{} = p) do
    %{
      "decision" => if(p.review_reason, do: "rejected", else: "approved"),
      "reason" => p.review_reason,
      "reviewed_at" => p.reviewed_at
    }
  end

  defp publication(%Project{published_slug: nil, import_message: nil}), do: nil

  defp publication(%Project{} = p) do
    %{
      "slug" => p.published_slug,
      "version" => p.published_version,
      "published_at" => p.published_at,
      "message" => p.import_message
    }
  end

  @doc "The author's declarations, `valid` only for the content revision they were made on."
  def attestations(%Project{attestations: nil}), do: nil

  def attestations(%Project{attestations: values} = p) do
    Map.merge(values, %{
      "attested_at" => p.attested_at,
      "valid" =>
        Enum.all?(~w(accuracy safety accessibility), &(values[&1] == true)) and
          p.attested_revision == p.content_revision
    })
  end
end
