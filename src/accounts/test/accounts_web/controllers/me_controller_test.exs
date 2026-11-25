defmodule MlAccountsWeb.MeControllerTest do
  use MlAccountsWeb.ConnCase, async: true

  @new_password "a brand new passphrase"

  setup do
    %{user: user_fixture()}
  end

  defp change_password(user, params, session \\ nil) do
    conn = build_conn() |> internal(user.id)
    conn = if session, do: with_session(conn, session), else: conn
    put(conn, "/api/me/password", params)
  end

  defp valid_session?(token), do: MlAccounts.get_session_user(token) != nil

  describe "PATCH /api/me" do
    test "updates the display name and bio, never the role or email", %{user: user} do
      params = %{
        display_name: "  Léa of the Grove ",
        bio: "Reads the stars.",
        role: "admin",
        email: "x@example.test"
      }

      assert %{
               "user" => %{
                 "display_name" => "Léa of the Grove",
                 "bio" => "Reads the stars.",
                 "role" => "user",
                 "email" => email
               }
             } =
               build_conn() |> internal(user.id) |> patch("/api/me", params) |> json_response(200)

      assert email == user.email
    end

    test "an empty display name falls back to the username; an empty bio is cleared", %{
      user: user
    } do
      build_conn()
      |> internal(user.id)
      |> patch("/api/me", %{display_name: "Someone", bio: "Hello"})
      |> json_response(200)

      assert %{"user" => %{"display_name" => display_name, "bio" => nil}} =
               build_conn()
               |> internal(user.id)
               |> patch("/api/me", %{display_name: " ", bio: ""})
               |> json_response(200)

      assert display_name == user.username
    end

    test "validates lengths", %{user: user} do
      params = %{display_name: String.duplicate("a", 61), bio: String.duplicate("b", 501)}

      assert %{
               "error" => "invalid",
               "errors" => %{
                 "display_name" => [_],
                 "bio" => ["should be at most 500 character(s)"]
               }
             } =
               build_conn() |> internal(user.id) |> patch("/api/me", params) |> json_response(422)
    end
  end

  describe "PUT /api/me/password" do
    test "changes the password and revokes every other session of the member", %{user: user} do
      current = session_fixture(user)
      other = session_fixture(user)
      someone_else = session_fixture(user_fixture())

      params = %{current_password: password(), password: @new_password}
      assert change_password(user, params, current) |> response(204) == ""

      assert valid_session?(current)
      refute valid_session?(other)
      assert valid_session?(someone_else)
      assert {:error, :invalid_credentials} = MlAccounts.login(user.email, password())
      assert {:ok, _token, _user} = MlAccounts.login(user.email, @new_password)
    end

    test "without x-session-token, all the member's sessions are revoked", %{user: user} do
      sessions = [session_fixture(user), session_fixture(user)]

      assert change_password(user, %{current_password: password(), password: @new_password})
             |> response(204)

      refute Enum.any?(sessions, &valid_session?/1)
    end

    test "401 for a wrong current password, 422 for an invalid new one", %{user: user} do
      session = session_fixture(user)

      assert %{"error" => "invalid_credentials"} =
               change_password(user, %{current_password: @new_password, password: @new_password})
               |> json_response(401)

      assert %{"error" => "invalid_credentials"} =
               change_password(user, %{password: @new_password}) |> json_response(401)

      assert %{
               "error" => "invalid",
               "errors" => %{"password" => ["should be at least 12 character(s)"]}
             } =
               change_password(user, %{current_password: password(), password: "too short"})
               |> json_response(422)

      assert valid_session?(session)
      assert {:ok, _token, _user} = MlAccounts.login(user.email, password())
    end
  end
end
