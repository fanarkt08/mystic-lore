defmodule MlStudio.AutosaveConcurrencyTest do
  # Real concurrency: separate connections (sandbox in :auto mode, real commits), explicit cleanup.
  use ExUnit.Case, async: false
  import MlStudio.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias MlStudio.{Projects, Repo}
  alias MlStudio.Projects.{Lesson, Project}

  setup do
    Sandbox.mode(Repo, :auto)
    owner = uuid()
    project = project_fixture(owner)

    on_exit(fn ->
      Repo.delete(Repo.get!(Project, project.id))
      Sandbox.mode(Repo, :manual)
    end)

    {:ok, owner: owner, project: project}
  end

  test "two collaborators saving the same lesson version at once: one wins, the other gets the conflict",
       %{
         owner: owner,
         project: p
       } do
    lesson = Repo.get_by!(Lesson, project_id: p.id, kind: "story")

    results =
      for text <- ~w(alpha beta gamma delta) do
        Task.async(fn ->
          Projects.update_lesson(owner, p.id, lesson.id, %{
            "lock_version" => lesson.lock_version,
            "body" => text
          })
        end)
      end
      |> Task.await_many(10_000)

    assert [{:ok, %Lesson{body: winner}}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &match?({:error, {:conflict, %Lesson{body: ^winner}}}, &1)) == 3

    saved = Repo.get!(Lesson, lesson.id)
    assert {saved.body, saved.lock_version} == {winner, lesson.lock_version + 1}
    # every content change bumps the project revision exactly once
    assert Repo.get!(Project, p.id).content_revision == p.content_revision + 1
  end
end
