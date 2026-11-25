defmodule MlAccountsWeb.UserControllerTest do
  use MlAccountsWeb.ConnCase, async: true

  # identité seulement : la bio et le reste du profil passent par le filtrage de visibilité
  @public_keys ["avatar", "display_name", "id", "username"]

  defp users(conn), do: conn |> json_response(200) |> Map.fetch!("users")

  defp search(caller, q),
    do: build_conn() |> internal(caller.id) |> get("/api/users/search", q: q)

  defp usernames(conn), do: conn |> users() |> Enum.map(& &1["username"])

  describe "GET /api/users?ids=" do
    test "returns public users, ignoring unknown and malformed ids" do
      a = user_fixture()
      b = user_fixture()
      ids = Enum.join([a.id, Ecto.UUID.generate(), "not-a-uuid", b.id, a.id], ",")

      found = build_conn() |> internal() |> get("/api/users", ids: ids) |> users()
      assert found |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.sort([a.id, b.id])
      assert Enum.all?(found, &(&1 |> Map.keys() |> Enum.sort() == @public_keys))
    end

    test "accepts up to 100 ids" do
      ids = fn n -> Enum.map_join(1..n, ",", fn _ -> Ecto.UUID.generate() end) end
      assert build_conn() |> internal() |> get("/api/users", ids: ids.(100)) |> users() == []

      assert %{"error" => "invalid", "errors" => %{"ids" => [_]}} =
               build_conn()
               |> internal()
               |> get("/api/users", ids: ids.(101))
               |> json_response(422)

      assert build_conn() |> internal() |> get("/api/users") |> users() == []
    end
  end

  describe "GET /api/users/search" do
    test "matches username or display name prefixes, case-insensitively, without the caller" do
      me = user_fixture(username: "lea_moreau", display_name: "Léa Moreau")
      user_fixture(username: "lemon_fox", display_name: "Fox")
      user_fixture(username: "hugo_bernard", display_name: "Lena Player")
      user_fixture(username: "ines_petit", display_name: "Inès lea")
      user_fixture(username: "lea_pending", confirmed: false)

      assert usernames(search(me, "LE")) == ["hugo_bernard", "lemon_fox"]
      assert usernames(search(me, " lemo ")) == ["lemon_fox"]
      assert usernames(search(me, "lena p")) == ["hugo_bernard"]

      assert search(me, "fox")
             |> users()
             |> Enum.all?(&(&1 |> Map.keys() |> Enum.sort() == @public_keys))
    end

    test "escapes LIKE wildcards" do
      me = user_fixture()
      user_fixture(username: "under_score")
      user_fixture(username: "underdog")

      assert usernames(search(me, "%%")) == []
      assert usernames(search(me, "under_")) == ["under_score"]
      assert usernames(search(me, "unde__")) == []
      assert usernames(search(me, "\\\\")) == []
    end

    test "returns at most 20 users" do
      me = user_fixture()
      for i <- 1..21, do: user_fixture(username: "bulk_#{i}")
      assert length(usernames(search(me, "bulk"))) == 20
    end

    test "q needs at least 2 characters" do
      me = user_fixture()

      for q <- ["a", " a ", nil] do
        assert %{"error" => "invalid", "errors" => %{"q" => [_]}} =
                 search(me, q) |> json_response(422)
      end
    end

    test "requires a user in the internal token" do
      assert %{"error" => "unauthorized"} =
               build_conn()
               |> internal()
               |> get("/api/users/search", q: "ab")
               |> json_response(401)

      assert %{"error" => "unauthorized"} =
               build_conn()
               |> internal(Ecto.UUID.generate())
               |> get("/api/users/search", q: "ab")
               |> json_response(401)
    end
  end

  describe "GET /api/users/by-username/:username" do
    test "returns the public user (case-insensitive), or 404" do
      user = user_fixture(username: "sarah_lefevre", display_name: "Sarah Lefèvre")

      assert %{"user" => found} =
               build_conn()
               |> internal()
               |> get("/api/users/by-username/Sarah_Lefevre")
               |> json_response(200)

      assert found == %{
               "id" => user.id,
               "username" => "sarah_lefevre",
               "display_name" => "Sarah Lefèvre",
               "avatar" => nil
             }

      assert %{"error" => "not_found"} =
               build_conn()
               |> internal()
               |> get("/api/users/by-username/nobody")
               |> json_response(404)
    end
  end
end
