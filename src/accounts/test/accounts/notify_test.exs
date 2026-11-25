defmodule MlAccounts.NotifyTest do
  @moduledoc """
  Catégories `security` et `account` : chaque événement met en file une notification Oban avec une clé propre,
  et la tâche suit la réponse du centre (faux endpoint).
  """
  use MlAccountsWeb.ConnCase, async: true
  use Oban.Testing, repo: MlAccounts.Repo
  alias MlAccounts.{NotifyWorker, Sanctions, TwoFactor}

  @moduletag :capture_log

  defp notifications(user_id) do
    for job <- Enum.sort_by(all_enqueued(worker: NotifyWorker), & &1.id),
        job.args["user_id"] == user_id,
        do: job.args
  end

  defp kinds(user_id), do: Enum.map(notifications(user_id), &{&1["category"], &1["kind"]})

  test "security: password changed, sessions revoked by the member; logging out is not notified" do
    user = user_fixture()
    token = session_fixture(user)
    new_password = "a brand new passphrase"

    {:ok, user} =
      MlAccounts.change_password(
        user,
        %{"current_password" => password(), "password" => new_password},
        token
      )

    assert [
             %{
               "kind" => "password_changed",
               "params" => %{"method" => "settings"},
               "dedupe_key" => key
             }
           ] =
             notifications(user.id)

    assert key =~ ~r/^security:password_changed:[0-9a-f-]{36}$/

    {:ok, keep, _} = MlAccounts.login(user.email, new_password)
    {:ok, _other, _} = MlAccounts.login(user.email, new_password)
    :ok = MlAccounts.revoke_other_sessions(user, keep)

    assert [_, %{"kind" => "sessions_revoked", "params" => %{"count" => count}}] =
             notifications(user.id)

    assert count >= 1

    MlAccounts.revoke_session(keep)
    assert length(notifications(user.id)) == 2
  end

  test "security: two-factor on, recovery codes regenerated, two-factor off" do
    user = user_fixture()
    {user, secret, _codes} = two_factor_fixture(user)
    {:ok, _codes} = TwoFactor.regenerate_recovery_codes(user, password())
    :ok = TwoFactor.disable(user, password(), totp(secret))

    assert kinds(user.id) == [
             {"security", "two_factor_enabled"},
             {"security", "recovery_codes_regenerated"},
             {"security", "two_factor_disabled"}
           ]

    # three events, three distinct keys
    assert notifications(user.id) |> Enum.map(& &1["dedupe_key"]) |> Enum.uniq() |> length() == 3
  end

  test "account: sanction issued and lifted, appeal decided, one key per event" do
    member = user_fixture()
    mod = user_fixture() |> Ecto.Changeset.change(role: "moderator") |> Repo.update!()
    admin = user_fixture() |> Ecto.Changeset.change(role: "admin") |> Repo.update!()

    {:ok, sanction, :created} =
      Sanctions.issue(mod, member.id, %{
        "kind" => "restriction",
        "reason" => "Spam in the forum, again.",
        "duration_hours" => 2
      })

    {:ok, appeal} =
      Sanctions.appeal(member, sanction.id, %{"body" => "This was a misunderstanding, please."})

    {:ok, _} =
      Sanctions.decide(admin, appeal.id, %{
        "decision" => "accept",
        "reason" => "Fair point, lifted."
      })

    assert [issued, decided] = notifications(member.id)

    assert %{
             "category" => "account",
             "kind" => "sanction_issued",
             "params" => %{"sanction_kind" => "restriction", "sanction_id" => sid, "ends_at" => _},
             "dedupe_key" => key
           } = issued

    assert sid == sanction.id and key == "sanction:#{sanction.id}:issued"
    # the reason (written by the staff) never goes to the notification
    refute inspect(issued) =~ "Spam"

    assert %{"kind" => "appeal_decided", "params" => %{"outcome" => "accepted"}} = decided
  end

  test "the worker posts to the center and follows its answer" do
    test = self()

    args = %{
      "user_id" => Ecto.UUID.generate(),
      "category" => "security",
      "kind" => "sessions_revoked",
      "params" => %{},
      "dedupe_key" => "security:sessions_revoked:x"
    }

    stub = fn status ->
      Req.Test.stub(MlShared.Client, fn conn ->
        [svc] = Plug.Conn.get_req_header(conn, "x-ml-service")
        send(test, {:center, svc, conn.request_path})
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"status" => "created"})
      end)
    end

    stub.(201)
    assert :ok = perform_job(NotifyWorker, args)
    assert_received {:center, "notifications", "/api/internal/notifications"}

    stub.(403)
    assert {:cancel, _} = perform_job(NotifyWorker, args)

    stub.(503)
    assert {:error, _} = perform_job(NotifyWorker, args)
  end
end
