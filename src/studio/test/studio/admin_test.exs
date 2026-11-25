defmodule MlStudio.AdminTest do
  @moduledoc "Audit central des décisions du staff et indicateurs."
  use MlStudio.DataCase, async: true
  alias MlStudio.Publishing
  alias MlStudio.Projects.Project

  setup do
    owner = uuid()
    staff = uuid()

    {:ok, project} =
      owner |> project_fixture() |> attested() |> then(&Publishing.submit(owner, &1.id))

    %{owner: owner, staff: staff, project: project}
  end

  defp routes(staff, role, audit \\ {201, %{"id" => 1}}),
    do: %{
      {"GET", "/api/internal/users/#{staff}"} => %{"user" => %{"id" => staff, "role" => role}},
      {"POST", "/api/internal/audit"} => audit
    }

  test "approve and reject are audited in the transaction; no audit, no decision", ctx do
    stub_services(routes(ctx.staff, "moderator", :unavailable))
    assert {:error, :audit_unavailable} = Publishing.approve(ctx.staff, ctx.project.id)
    assert Repo.get!(Project, ctx.project.id).status == "submitted"
    refute_enqueued(worker: MlStudio.Publishing.ImportWorker)

    stub_services(routes(ctx.staff, "moderator"))

    assert {:ok, %Project{status: "draft"}} =
             Publishing.reject(ctx.staff, ctx.project.id, %{"reason" => "Add image texts."})

    assert_received {:service,
                     %{
                       path: "/api/internal/audit",
                       body: %{
                         "action" => "studio.project.rejected",
                         "actor_id" => actor,
                         "reason" => "Add image texts.",
                         "metadata" => %{"owner_id" => owner}
                       }
                     }}

    assert {actor, owner} == {ctx.staff, ctx.owner}
  end

  test "stats: staff only, real counts", ctx do
    stub_services(routes(ctx.staff, "user"))
    assert {:error, :forbidden} = Publishing.stats(ctx.staff)

    stub_services(routes(ctx.staff, "admin"))

    assert {:ok, %{review_queue: 1, failed_generations_24h: 0}} = Publishing.stats(ctx.staff)
  end
end
