defmodule MysticWeb.MemberSettingsLiveTest do
  use MysticWeb.ConnCase, async: true

  describe "member profile" do
    setup do
      user = user_fixture()
      hugo = member_fixture(%{"bio" => "Stargazer and map maker."})

      routes =
        Map.merge(member_routes(user), %{
          {"GET", "/api/users/by-username/hugo_bernard/profile"} => %{
            "profile" => profile_fixture(hugo)
          },
          {"GET", "/api/me/friends"} => %{"friends" => []},
          {"GET", "/api/me/friend-requests"} => %{"incoming" => [], "outgoing" => []},
          {"GET", "/api/me/blocks"} => %{"blocks" => []}
        })

      %{user: user, hugo: hugo, routes: routes}
    end

    test "shows the public profile and sends a friend request", %{
      conn: conn,
      routes: routes,
      hugo: hugo
    } do
      stub_api(
        Map.put(
          routes,
          {"POST", "/api/friend-requests"},
          {201, %{"id" => "r1", "status" => "pending"}}
        )
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/members/hugo_bernard")

      assert has_element?(view, "#member-name", "Hugo Bernard")
      assert has_element?(view, "#member-profile", "Stargazer and map maker.")

      view |> element("button", "Add friend") |> render_click()

      assert_received {:api,
                       %{method: "POST", path: "/api/friend-requests", body: %{"user_id" => id}}}

      assert id == hugo["id"]
    end

    test "friends can be messaged, blocked or reported", %{
      conn: conn,
      routes: routes,
      hugo: hugo
    } do
      stub_api(
        Map.merge(routes, %{
          {"GET", "/api/me/friends"} => %{"friends" => [hugo]},
          {"POST", "/api/blocks"} => {204, nil},
          {"POST", "/api/reports"} => {201, %{"id" => "rep1"}},
          {"POST", "/api/conversations"} => %{"conversation" => %{"id" => "c9"}}
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/members/hugo_bernard")
      assert has_element?(view, "#member-profile", "Friend")

      view |> element("button", "Block") |> render_click()
      assert_received {:api, %{method: "POST", path: "/api/blocks"}}

      view |> element("button", "Report") |> render_click()

      view
      |> form("#report-form", report: %{reason: "harassment", details: ""})
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "POST",
                         path: "/api/reports",
                         body: %{"target_type" => "user", "reason" => "harassment"}
                       }}

      view |> element("button", "Message") |> render_click()
      assert_redirect(view, ~p"/messages/c9")
    end

    test "own profile and unknown members", %{conn: conn, routes: routes, user: user} do
      stub_api(
        Map.put(routes, {"GET", "/api/users/by-username/lea_moreau/profile"}, %{
          "profile" => profile_fixture(user)
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/members/lea_moreau")
      assert has_element?(view, "#member-profile", "This is your public profile.")
      refute has_element?(view, "button", "Add friend")

      assert_error_sent 404, fn -> conn |> log_in() |> get(~p"/members/nobody") end
    end
  end

  describe "settings" do
    test "updates the profile through accounts", %{conn: conn} do
      user = user_fixture()

      stub_api(
        Map.merge(member_routes(user), %{
          {"PATCH", "/api/me"} => fn _conn, body -> %{"user" => Map.merge(user, body)} end
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings")

      view
      |> form("#profile-form", profile: %{display_name: "Léa the Wise", bio: "Grove keeper."})
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "PATCH",
                         path: "/api/me",
                         body: %{"display_name" => "Léa the Wise", "bio" => "Grove keeper."}
                       }}

      assert render(view) =~ "Profile saved."
      assert has_element?(view, ".rail-user", "Léa the Wise")
    end

    test "shows validation errors", %{conn: conn} do
      user = user_fixture()

      stub_api(
        Map.merge(member_routes(user), %{
          {"PATCH", "/api/me"} =>
            {422, %{"error" => "invalid", "errors" => %{"display_name" => ["can't be blank"]}}}
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings")
      view |> form("#profile-form", profile: %{display_name: "", bio: ""}) |> render_submit()
      assert has_element?(view, "#profile_display_name-error", "can't be blank")
    end

    test "changes the password, or explains a wrong current password", %{conn: conn} do
      user = user_fixture()

      stub_api(
        Map.merge(member_routes(user), %{
          {"PUT", "/api/me/password"} => fn _conn, %{"current_password" => current} ->
            if current == "good-old-password",
              do: {204, nil},
              else: {401, %{"error" => "invalid_credentials"}}
          end
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/settings/account")

      view
      |> form("#password-form",
        password: %{current_password: "wrong", password: "a-brand-new-password"}
      )
      |> render_submit()

      assert has_element?(
               view,
               "#password_current_password-error",
               "This is not your current password."
             )

      view
      |> form("#password-form",
        password: %{current_password: "good-old-password", password: "a-brand-new-password"}
      )
      |> render_submit()

      assert render(view) =~ "Password changed. Your other sessions have been signed out."
    end
  end
end
