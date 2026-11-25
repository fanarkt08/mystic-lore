defmodule MysticWeb.Preferences.ProfilePagesTest do
  @moduledoc "Profile open to visitors, avatars served by web, identity next to contributions, dashboard."
  use MysticWeb.ConnCase, async: true

  @record %{
    "user_id" => "x",
    "level" => 2,
    "xp" => 240,
    "badges_earned" => 6,
    "adventures_completed" => 1,
    "equipped_badges" => []
  }

  describe "/members/:username" do
    test "a visitor sees a public profile, without any member action", %{conn: conn} do
      lea = member_fixture(%{"username" => "lea_moreau", "display_name" => "Léa Moreau"})

      profile =
        profile_fixture(lea, %{
          "visibility" => "public",
          "details" => %{
            "bio" => "Night owl.",
            "pronouns" => "she/her",
            "interests" => ["astronomy"]
          }
        })

      stub_api(%{
        {"GET", "/api/users/by-username/lea_moreau/profile"} => %{"profile" => profile},
        {"GET", "/api/users/#{lea["id"]}/profile"} => @record
      })

      {:ok, view, _html} = live(conn, ~p"/members/lea_moreau")
      assert has_element?(view, "#member-name", "Léa Moreau")
      assert has_element?(view, "#member-profile-pronouns", "she/her")
      assert has_element?(view, "#member-profile-interests", "Astronomy")
      assert has_element?(view, "#member-record", "240")
      refute has_element?(view, "button", "Add friend")
      refute has_element?(view, "button", "Report")
      # no member in the internal token: accounts filters for a visitor
      assert_received {:api, %{path: "/api/users/by-username/lea_moreau/profile"}}
    end

    test "hidden details: a notice, and learning is never asked for the record", %{conn: conn} do
      sarah = member_fixture(%{"username" => "sarah_lefevre", "display_name" => "Sarah Lefèvre"})

      hidden =
        profile_fixture(sarah, %{
          "visibility" => "friends",
          "details" => nil,
          "academy_record" => false
        })

      stub_api(%{
        {"GET", "/api/users/by-username/sarah_lefevre/profile"} => %{"profile" => hidden}
      })

      {:ok, view, _html} = live(conn, ~p"/members/sarah_lefevre")
      assert has_element?(view, "#member-profile-hidden", "with their friends only")
      refute has_element?(view, "#member-record")
      learning = "/api/users/#{sarah["id"]}/profile"
      refute_received {:api, %{path: ^learning}}
    end
  end

  describe "/media/avatars/:key" do
    @key String.duplicate("ab", 16) <> ".png"

    test "relays the current image with its detected type, nosniff, a versioned cache", %{
      conn: conn
    } do
      png = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "body">>

      stub_api(%{
        {"GET", "/api/avatars/#{@key}"} => fn conn, _ ->
          conn |> Plug.Conn.put_resp_content_type("text/html") |> Plug.Conn.send_resp(200, png)
        end
      })

      conn = get(conn, "/media/avatars/#{@key}")
      assert response(conn, 200) == png
      # the type comes from the bytes, never from what the source said
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert ["public, max-age=86400, immutable"] = get_resp_header(conn, "cache-control")
    end

    test "unknown names, other formats and oversized bodies are 404", %{conn: conn} do
      stub_api(%{
        {"GET", "/api/avatars/#{@key}"} => fn conn, _ ->
          Plug.Conn.send_resp(conn, 200, "<svg onload=alert(1)>")
        end
      })

      assert conn |> get("/media/avatars/#{@key}") |> response(404)
      assert build_conn() |> get("/media/avatars/..%2F..%2Fetc%2Fpasswd") |> response(404)
      assert build_conn() |> get("/media/avatars/nothex.png") |> response(404)

      big = <<0xFF, 0xD8, 0xFF>> <> :binary.copy(<<0>>, 2_097_152)

      stub_api(%{
        {"GET", "/api/avatars/#{@key}"} => fn conn, _ -> Plug.Conn.send_resp(conn, 200, big) end
      })

      assert build_conn() |> get("/media/avatars/#{@key}") |> response(404)
    end
  end

  test "identity next to a forum post: avatar, display name and @username" do
    html =
      render_component(&MysticWeb.MysticComponents.identity/1,
        user: %{
          "id" => "u1",
          "username" => "hugo_bernard",
          "display_name" => "Hugo Bernard",
          "avatar" => %{"kind" => "crest", "key" => "star"}
        }
      )

    assert html =~ ~s(src="/images/crests/star.svg")
    assert html =~ "Hugo Bernard"
    assert html =~ "@hugo_bernard"
    assert html =~ ~s(href="/members/hugo_bernard")

    deleted =
      render_component(&MysticWeb.MysticComponents.identity/1,
        user: %{
          "id" => "u2",
          "username" => "deleted_0123456789abcdef",
          "display_name" => "Deleted member"
        }
      )

    assert deleted =~ "Deleted member"
    refute deleted =~ "@deleted_"
  end

  describe "dashboard" do
    test "daily goal from today's XP; interests order the recommendations", %{conn: conn} do
      user =
        user_fixture(%{
          "interests" => ["writing", "astronomy", "art"],
          "preferences" => %{"daily_xp_goal" => 50}
        })

      week =
        for d <- 6..0//-1,
            do: %{"date" => Date.to_iso8601(Date.add(Date.utc_today(), -d)), "xp" => 5 * d}

      week = List.update_at(week, 6, &Map.put(&1, "xp", 35))

      stub_api(
        Map.merge(member_routes(user), %{
          {"GET", "/api/me/dashboard"} => %{
            "level" => 1,
            "xp" => 35,
            "into_level" => 35,
            "per_level" => 150,
            "streak" => 1,
            "week" => week,
            "current" => nil,
            "recommendations" => [],
            "quests" => [],
            "equipped_badges" => [],
            "badges_earned" => 0,
            "badges_total" => 10
          },
          {"GET", "/api/me/billing"} => billing(user["id"]),
          {"GET", "/api/me/friend-requests"} => %{"incoming" => [], "outgoing" => []}
        })
      )

      {:ok, view, _html} = conn |> log_in() |> live(~p"/dashboard")
      assert has_element?(view, "#goal-progress", "35 / 50 XP today")

      assert has_element?(
               view,
               "#daily-goal [role=progressbar][aria-valuenow='35'][aria-valuemax='50']"
             )

      assert has_element?(view, "#reco-interests", "Writing & storytelling")
      # creative (2 interests) before science (1)
      assert_received {:api,
                       %{path: "/api/me/dashboard", query: %{"categories" => "creative,science"}}}
    end
  end
end
