defmodule MlAccountsWeb.AccountDeletionTest do
  use MlAccountsWeb.ConnCase, async: true
  use Oban.Testing, repo: MlAccounts.Repo
  import Ecto.Query, only: [from: 2]
  import Swoosh.TestAssertions
  alias MlAccounts.{DeletionStep, Privacy, Session, User}
  alias MlAccounts.Privacy.DeletionWorker

  @moduletag :capture_log
  @order ~w(multiplayer studio community social billing learning notifications)

  setup do
    user = user_fixture(%{display_name: "Léa Moreau", bio: "Botanist."})
    MlShared.Events.subscribe("user:#{user.id}")
    %{user: user, token: session_fixture(user)}
  end

  # Faux services : DELETE interne → 204, sauf ceux de `down` (injoignables). Chaque appel est rapporté au test.
  defp stub_services(down \\ []) do
    test = self()

    Req.Test.stub(MlShared.Client, fn conn ->
      [service] = Plug.Conn.get_req_header(conn, "x-ml-service")
      send(test, {:called, conn.method, service, conn.request_path})

      if service in down,
        do: Req.Test.transport_error(conn, :econnrefused),
        else: Plug.Conn.send_resp(conn, 204, "")
    end)
  end

  # `{service, chemin}` des DELETE reçus depuis le dernier relevé (boîte aux lettres vidée).
  defp deletes(acc \\ []) do
    receive do
      {:called, "DELETE", service, path} -> deletes([{service, path} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp calls, do: Enum.map(deletes(), &elem(&1, 0))

  defp as(user), do: build_conn() |> internal(user.id)

  defp schedule(user, params \\ %{}) do
    params = Map.merge(%{password: password(), confirm_username: user.username}, params)
    user |> as() |> post("/api/me/deletion", params)
  end

  defp make_due(user) do
    past = DateTime.add(DateTime.utc_now(:second), -60)
    Repo.update_all(from(u in User, where: u.id == ^user.id), set: [deletion_scheduled_at: past])
  end

  defp login(user),
    do:
      build_conn() |> internal() |> post("/api/sessions", email: user.email, password: password())

  describe "scheduling" do
    test "password and exact username required; J+30, every session revoked, e-mail sent", %{
      user: user,
      token: token
    } do
      assert schedule(user, %{password: "wrong password!"}) |> json_response(401)

      assert %{"errors" => %{"confirm_username" => [_]}} =
               schedule(user, %{confirm_username: "someone_else"}) |> json_response(422)

      assert MlAccounts.get_session_user(token)

      assert %{"deletion_scheduled_at" => at} = schedule(user) |> json_response(200)
      {:ok, at, _} = DateTime.from_iso8601(at)
      assert_in_delta DateTime.diff(at, DateTime.utc_now()), 30 * 86_400, 60

      refute MlAccounts.get_session_user(token)
      assert_receive {:sessions_revoked, _}
      assert_email_sent(subject: "Your MysticLore account will be deleted")

      # déjà programmée : même échéance, aucun nouvel e-mail
      assert %{"deletion_scheduled_at" => again} = schedule(user) |> json_response(200)
      assert again == DateTime.to_iso8601(at)
      refute_email_sent()
    end

    test "login stays possible during the grace period and returns the date; cancel", %{
      user: user
    } do
      schedule(user) |> json_response(200)

      assert %{"session_token" => token, "user" => %{"deletion_scheduled_at" => at}} =
               login(user) |> json_response(201)

      assert is_binary(at)

      assert %{"user" => %{"deletion_scheduled_at" => ^at}} =
               build_conn()
               |> internal()
               |> with_session(token)
               |> get("/api/sessions/current")
               |> json_response(200)

      assert user |> as() |> delete("/api/me/deletion") |> response(204)
      assert Repo.reload!(user).deletion_scheduled_at == nil

      assert %{"error" => "not_found"} =
               user |> as() |> delete("/api/me/deletion") |> json_response(404)

      stub_services()
      Privacy.enqueue_due_deletions()
      refute_enqueued(worker: DeletionWorker)
      assert :ok = Privacy.execute_deletion(user.id)
      assert calls() == []
    end
  end

  describe "execution at the due date" do
    setup %{user: user} do
      schedule(user) |> json_response(200)
      make_due(user)
      :ok
    end

    test "login refused, no cancellation; every service called in order, then anonymised", %{
      user: user
    } do
      assert %{"error" => "account_deleted"} = login(user) |> json_response(403)

      # le compte n'agit plus : ni annulation, ni autre route « utilisateur »
      assert user |> as() |> delete("/api/me/deletion") |> json_response(401)
      assert {:error, :deletion_in_progress} = Privacy.cancel_deletion(user)

      assert Privacy.enqueue_due_deletions() == 1
      assert Privacy.enqueue_due_deletions() == 1
      assert [_one] = all_enqueued(worker: DeletionWorker)

      stub_services()
      assert :ok = perform_job(DeletionWorker, %{user_id: user.id})
      assert deletes() == Enum.map(@order, &{&1, "/api/internal/users/#{user.id}"})

      deleted = Repo.reload!(user)
      assert deleted.email == "deleted-#{user.id}@deleted.invalid"
      assert "deleted_" <> short = deleted.username
      assert byte_size(short) == 16
      assert deleted.display_name == "Deleted member"
      assert deleted.bio == nil
      assert deleted.role == "user"
      assert deleted.deleted_at
      refute deleted.hashed_password == user.hashed_password
      assert Repo.aggregate(from(s in Session, where: s.user_id == ^user.id), :count) == 0

      steps = Repo.all(from s in DeletionStep, where: s.user_id == ^user.id, select: s.service)
      assert Enum.sort(steps) == Enum.sort(["accounts" | @order])

      # plus de connexion possible (ni avec l'ancienne adresse, ni avec la nouvelle)
      assert %{"error" => "invalid_credentials"} = login(user) |> json_response(401)

      assert build_conn()
             |> internal()
             |> post("/api/sessions", email: deleted.email, password: password())
             |> json_response(401)

      # profils publics : « Deleted member », plus de page par pseudonyme ni de recherche
      assert %{"users" => [%{"display_name" => "Deleted member", "avatar" => nil}]} =
               build_conn()
               |> internal()
               |> get("/api/users?ids=#{user.id}")
               |> json_response(200)

      for name <- [user.username, deleted.username] do
        assert build_conn()
               |> internal()
               |> get("/api/users/by-username/#{name}")
               |> json_response(404)
      end

      other = user_fixture()

      assert %{"users" => []} =
               other |> as() |> get("/api/users/search?q=deleted") |> json_response(200)

      # rejouer ne fait plus rien
      assert :ok = Privacy.execute_deletion(user.id)
      assert calls() == []
    end

    test "an unavailable service stops the run; the retry skips the steps already done", %{
      user: user
    } do
      stub_services(["social"])
      assert {:error, {:social, "unavailable"}} = Privacy.execute_deletion(user.id)
      assert calls() == ~w(multiplayer studio community social)
      assert Repo.reload!(user).deleted_at == nil

      # toujours due : la connexion reste refusée en attendant
      assert %{"error" => "account_deleted"} = login(user) |> json_response(403)

      stub_services()
      assert :ok = perform_job(DeletionWorker, %{user_id: user.id})
      assert calls() == ~w(social billing learning notifications)
      assert Repo.reload!(user).deleted_at
    end

    test "a service answering an error is not recorded as done", %{user: user} do
      Req.Test.stub(MlShared.Client, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      assert {:error, {:multiplayer, "HTTP 500"}} = Privacy.execute_deletion(user.id)
      assert Repo.all(from s in DeletionStep, where: s.user_id == ^user.id) == []
    end
  end

  test "registration can't take the names reserved for deleted accounts" do
    assert %{"errors" => errors} =
             build_conn()
             |> internal()
             |> post("/api/users", %{
               email: "deleted-x@deleted.invalid",
               username: "deleted_0123456789abcdef",
               password: password()
             })
             |> json_response(422)

    assert errors["email"] == ["is reserved"]
    assert errors["username"] == ["is reserved"]
  end
end
