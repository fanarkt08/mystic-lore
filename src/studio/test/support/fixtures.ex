defmodule MlStudio.Fixtures do
  @moduledoc "Fictional studio data built through the contexts."
  alias MlStudio.{Projects, Repo}
  alias MlStudio.Projects.Project

  def uuid, do: Ecto.UUID.generate()

  @brief %{
    "title" => "Le Jardin au clair de lune",
    "summary" => "Grow a moonlit garden while learning how loops repeat a spell.",
    "description" => "Three short lessons about repetition.",
    "objectives" => ["Read a loop", "Write a loop that waters every plant"],
    "audience" => "Curious beginners",
    "level" => "beginner",
    "duration_minutes" => 30,
    "category" => "coding",
    "cover" => "forest"
  }

  def brief, do: @brief

  @doc "A project owned by `owner_id` that passes every publication check (1 module, 3 lessons)."
  def project_fixture(owner_id, attrs \\ %{}) do
    {:ok, project} = Projects.create(owner_id, Map.merge(@brief, attrs))
    {:ok, module} = Projects.add_module(owner_id, project.id, %{"title" => "Seeds of Moonlight"})

    lesson!(owner_id, project, module, "story", "The Silver Seedling", %{
      "body" => "Moonlight falls on a sleeping garden."
    })

    lesson!(owner_id, project, module, "exercise", "Counting Petals", %{
      "body" => "The gardener asks a riddle.",
      "content" => %{
        "question" => "What does range(3) produce?",
        "choices" => ["1, 2, 3", "0, 1, 2"],
        "answer" => 1,
        "explanation" => "range(3) starts at 0 and stops before 3."
      }
    })

    lesson!(owner_id, project, module, "coding", "Watering the Moonwillows", %{
      "body" => "Four moonwillows wait in a row.",
      "content" => %{
        "plants" => 4,
        "starter" => "water(0)\n",
        "hints" => ["range(4) gives 0, 1, 2, 3."]
      }
    })

    Repo.get!(Project, project.id)
  end

  def lesson!(owner_id, project, module, kind, title, attrs) do
    {:ok, lesson} =
      Projects.add_lesson(owner_id, project.id, module.id, %{"title" => title, "kind" => kind})

    {:ok, lesson} =
      Projects.update_lesson(owner_id, project.id, lesson.id, Map.put(attrs, "lock_version", 1))

    lesson
  end

  @doc "The project with valid attestations for its current revision."
  def attested(%Project{} = project) do
    {:ok, project} =
      MlStudio.Publishing.attest(project.owner_id, project.id, %{
        "accuracy" => true,
        "safety" => true,
        "accessibility" => true
      })

    project
  end

  def png, do: <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> :crypto.strong_rand_bytes(64)
end
