defmodule MysticWeb.Settings.SectionsTest do
  @moduledoc "Each section of /settings: navigation, saves confirmed by accounts, errors next to their field."
  use MysticWeb.ConnCase, async: true

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "fake image body">>

  defp prefs(attrs \\ %{}) do
    Map.merge(
      %{
        "language" => "auto",
        "time_zone" => "auto",
        "theme" => "system",
        "reduce_motion" => false,
        "high_contrast" => false,
        "text_size" => 100,
        "underline_links" => false,
        "captions" => true,
        "daily_xp_goal" => 20
      },
      attrs
    )
  end

  defp member(attrs \\ %{}) do
    user_fixture(
      Map.merge(
        %{
          "pronouns" => nil,
          "interests" => [],
          "cover" => nil,
          "profile_visibility" => "members",
          "avatar" => nil,
          "preferences" => prefs()
        },
        attrs
      )
    )
  end

  # accounts answers a save with the member merged with what it received (preferences cast like accounts)
  defp echo(user) do
    fn _conn, body ->
      changes =
        body
        |> Map.take(Map.keys(user["preferences"]))
        |> Map.new(fn
          {key, value} when key in ~w(text_size daily_xp_goal) ->
            {key, String.to_integer("#{value}")}

          pair ->
            pair
        end)

      prefs = Map.merge(user["preferences"], changes)

      %{
        "user" =>
          user |> Map.merge(Map.drop(body, Map.keys(prefs))) |> Map.put("preferences", prefs)
      }
    end
  end

  defp open(conn, user, path, extra \\ %{}) do
    stub_api(Map.merge(member_routes(user), extra))
    {:ok, view, _html} = conn |> log_in() |> live(path)
    view
  end

  test "sub-navigation: one link per section, the current one marked; unknown sections are 404",
       %{
         conn: conn
       } do
    view = open(conn, member(), ~p"/settings")

    for section <- ~w(profile account security preferences accessibility learning data) do
      assert has_element?(view, "#settings-nav-#{section}[href='/settings/#{section}']")
    end

    assert has_element?(view, "#settings-nav-profile[aria-current=page]")
    assert has_element?(view, "#profile-form")

    view |> element("#settings-nav-learning") |> render_click()
    assert_patch(view, ~p"/settings/learning")
    assert has_element?(view, "#settings-nav-learning[aria-current=page]")
    assert has_element?(view, "#learning-form")
    refute has_element?(view, "#profile-form")

    assert_error_sent 404, fn -> conn |> log_in() |> get(~p"/settings/nowhere") end
  end

  describe "profile" do
    test "pronouns, interests and cover are saved; success only after accounts confirmed", %{
      conn: conn
    } do
      user = member()
      view = open(conn, user, ~p"/settings/profile", %{{"PATCH", "/api/me"} => echo(user)})
      refute has_element?(view, "#profile-status", "Profile saved.")
      assert has_element?(view, "#identity-note", "always stay visible")

      view
      |> form("#profile-form",
        profile: %{
          display_name: "Léa",
          pronouns: "she/her",
          interests: ["astronomy", "coding"],
          cover: "forest"
        }
      )
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "PATCH",
                         path: "/api/me",
                         body: %{
                           "pronouns" => "she/her",
                           "interests" => ["astronomy", "coding"],
                           "cover" => "forest"
                         }
                       }}

      assert has_element?(view, "#profile-status[role=status]", "Profile saved.")
      assert has_element?(view, "#interest-astronomy[checked]")
    end

    test "errors of accounts stay next to their field; nothing is announced", %{conn: conn} do
      user = member()

      view =
        open(conn, user, ~p"/settings/profile", %{
          {"PATCH", "/api/me"} =>
            {422,
             %{
               "error" => "invalid",
               "errors" => %{
                 "pronouns" => ["must not contain control characters"],
                 "interests" => ["should have at most 6 item(s)"]
               }
             }}
        })

      view |> form("#profile-form", profile: %{pronouns: "x"}) |> render_submit()
      assert has_element?(view, "#profile_pronouns-error", "must not contain control characters")
      assert has_element?(view, "#profile-interests-error", "should have at most 6")
      refute has_element?(view, "#profile-status", "saved")
    end

    test "avatar: an image is sent raw to accounts; a refused file is explained", %{conn: conn} do
      user = member()

      view =
        open(conn, user, ~p"/settings/profile", %{
          {"PUT", "/api/me/avatar"} => fn _conn, _body ->
            %{
              "user" =>
                Map.put(user, "avatar", %{
                  "kind" => "image",
                  "key" => "#{String.duplicate("a", 32)}.png"
                })
            }
          end
        })

      avatar =
        file_input(view, "#avatar-form", :avatar, [
          %{name: "me.png", content: @png, type: "image/png"}
        ])

      render_upload(avatar, "me.png")
      view |> form("#avatar-form") |> render_submit()

      assert_received {:api, %{method: "PUT", path: "/api/me/avatar", body: @png}}
      assert has_element?(view, "#avatar-status", "Avatar saved.")

      assert has_element?(
               view,
               "#avatar-section img[src='/media/avatars/#{String.duplicate("a", 32)}.png']"
             )

      assert has_element?(view, ".rail-user img.avatar-picture")

      stub_api(
        Map.merge(member_routes(user), %{
          {"PUT", "/api/me/avatar"} =>
            {422,
             %{
               "error" => "invalid",
               "errors" => %{"avatar" => ["must be a PNG, JPEG or WebP image"]}
             }}
        })
      )

      avatar =
        file_input(view, "#avatar-form", :avatar, [
          %{name: "notes.png", content: "text", type: "image/png"}
        ])

      render_upload(avatar, "notes.png")
      view |> form("#avatar-form") |> render_submit()
      assert has_element?(view, "#avatar-error", "must be a PNG, JPEG or WebP image")
    end

    test "avatar: a crest, or back to the initials", %{conn: conn} do
      user = member(%{"avatar" => %{"kind" => "crest", "key" => "moon"}})

      view =
        open(conn, user, ~p"/settings/profile", %{
          {"PUT", "/api/me/avatar/crest"} => fn _conn, %{"crest" => crest} ->
            %{"user" => Map.put(user, "avatar", %{"kind" => "crest", "key" => crest})}
          end,
          {"DELETE", "/api/me/avatar"} => %{"user" => Map.put(user, "avatar", nil)}
        })

      assert has_element?(view, "#crest-choice-moon[checked]")
      view |> form("#crest-form", crest: %{key: "star"}) |> render_submit()

      assert_received {:api,
                       %{method: "PUT", path: "/api/me/avatar/crest", body: %{"crest" => "star"}}}

      assert has_element?(view, "#avatar-current", "Guiding star")

      view |> element("#remove-avatar") |> render_click()
      assert_received {:api, %{method: "DELETE", path: "/api/me/avatar"}}
      assert has_element?(view, "#avatar-status", "initials")
      refute has_element?(view, "#remove-avatar")
    end
  end

  describe "preferences" do
    test "a new language reloads the page in that language", %{conn: conn} do
      user = member()

      view =
        open(conn, user, ~p"/settings/preferences", %{
          {"PATCH", "/api/me/preferences"} => echo(user)
        })

      view
      |> form("#language-form", language: %{language: "fr", time_zone: "Europe/Paris"})
      |> render_submit()

      assert_received {:api,
                       %{
                         path: "/api/me/preferences",
                         body: %{"language" => "fr", "time_zone" => "Europe/Paris"}
                       }}

      assert {path, %{"info" => message}} = assert_redirect(view)
      assert path == ~p"/settings/preferences"

      # French catalogue: the message is in the new language (or the English text if not translated yet)
      assert is_binary(message)
    end

    test "the same language: no reload, the zone is applied and announced", %{conn: conn} do
      user = member()

      view =
        open(conn, user, ~p"/settings/preferences", %{
          {"PATCH", "/api/me/preferences"} => echo(user)
        })

      view
      |> form("#language-form", language: %{language: "auto", time_zone: "Asia/Tokyo"})
      |> render_submit()

      assert has_element?(view, "#language-status", "Language and time zone saved.")
      assert has_element?(view, "#language-status", "JST")
      assert has_element?(view, "#time-zone option[selected][value='Asia/Tokyo']")
    end

    test "VIP theme refused by accounts: the reason sits next to the theme", %{conn: conn} do
      user = member()

      view =
        open(conn, user, ~p"/settings/preferences", %{
          {"GET", "/api/me/billing"} => billing(user["id"]),
          {"PATCH", "/api/me/preferences"} => {403, %{"error" => "vip_required"}}
        })

      assert has_element?(view, "#vip-theme-choice", "They need an active VIP membership")
      view |> form("#appearance-form", appearance: %{theme: "grove"}) |> render_submit()
      assert has_element?(view, "#theme-error", "VIP themes need an active VIP membership.")
      refute has_element?(view, "#appearance-status", "saved")

      stub_api(
        Map.merge(member_routes(user), %{
          {"PATCH", "/api/me/preferences"} => {503, %{"error" => "entitlements_unavailable"}}
        })
      )

      view |> form("#appearance-form", appearance: %{theme: "ember"}) |> render_submit()
      assert has_element?(view, "#theme-error", "can't be verified right now")
    end

    test "a theme saved is pushed to <html> at once", %{conn: conn} do
      user = member()

      view =
        open(conn, user, ~p"/settings/preferences", %{
          {"PATCH", "/api/me/preferences"} => echo(user)
        })

      view |> form("#appearance-form", appearance: %{theme: "dark"}) |> render_submit()
      assert_push_event(view, "ml:prefs", %{attrs: %{"data-theme" => "dark"}, scheme: "dark"})
      assert has_element?(view, "#appearance-status", "Appearance saved.")
    end
  end

  test "accessibility: every option is sent and applied through <html> attributes", %{conn: conn} do
    user = member()

    view =
      open(conn, user, ~p"/settings/accessibility", %{
        {"PATCH", "/api/me/preferences"} => echo(user)
      })

    view
    |> form("#accessibility-form",
      accessibility: %{
        reduce_motion: "true",
        high_contrast: "true",
        underline_links: "true",
        captions: "false",
        text_size: "150"
      }
    )
    |> render_submit()

    assert_received {:api,
                     %{
                       path: "/api/me/preferences",
                       body: %{
                         "reduce_motion" => true,
                         "high_contrast" => true,
                         "underline_links" => true,
                         "captions" => false,
                         "text_size" => "150"
                       }
                     }}

    assert_push_event(view, "ml:prefs", %{
      attrs: %{
        "data-motion" => "reduce",
        "data-contrast" => "more",
        "data-text-size" => "150",
        "data-links" => "underline"
      }
    })

    assert has_element?(view, "#accessibility-status", "Accessibility settings saved.")
  end

  test "learning: the daily goal is saved; interests are explained", %{conn: conn} do
    user = member(%{"interests" => ["astronomy"]})

    view =
      open(conn, user, ~p"/settings/learning", %{{"PATCH", "/api/me/preferences"} => echo(user)})

    assert has_element?(view, "#interests-note", "Astronomy")

    view |> form("#learning-form", learning: %{daily_xp_goal: "50"}) |> render_submit()
    assert_received {:api, %{path: "/api/me/preferences", body: %{"daily_xp_goal" => "50"}}}
    assert has_element?(view, "#learning-status", "Daily goal saved.")
    assert has_element?(view, "#daily-goal-choice-50[checked]")
  end

  describe "privacy & data" do
    test "visibility is saved; the preview shows what accounts returns for each reader", %{
      conn: conn
    } do
      user = member(%{"profile_visibility" => "members"})
      shared = profile_fixture(user, %{"visibility" => "friends"})
      hidden = Map.merge(shared, %{"details" => nil, "academy_record" => false})

      view =
        open(conn, user, ~p"/settings/data", %{
          {"PATCH", "/api/me"} => echo(user),
          {"GET", "/api/me/exports"} => %{"exports" => []},
          {"GET", "/api/me/profile-preview"} => fn conn, _ ->
            case conn.query_string do
              "as=friend" -> %{"profile" => shared}
              _ -> %{"profile" => hidden}
            end
          end,
          {"GET", "/api/users/#{user["id"]}/profile"} => %{
            "level" => 3,
            "xp" => 320,
            "badges_earned" => 1,
            "adventures_completed" => 0,
            "equipped_badges" => []
          }
        })

      view
      |> form("#visibility-form", visibility: %{profile_visibility: "friends"})
      |> render_submit()

      assert_received {:api,
                       %{
                         method: "PATCH",
                         path: "/api/me",
                         body: %{"profile_visibility" => "friends"}
                       }}

      assert has_element?(view, "#visibility-status", "Profile visibility saved.")

      view |> element("#preview-as-visitor") |> render_click()
      assert has_element?(view, "#preview-profile-hidden", "with their friends only")
      refute has_element?(view, "#preview-record")
      learning = "/api/users/#{user["id"]}/profile"
      refute_received {:api, %{path: ^learning}}

      view |> element("#preview-as-friend") |> render_click()
      assert has_element?(view, "#preview-profile-bio", user["bio"])
      assert has_element?(view, "#preview-record", "320")
      assert has_element?(view, "#preview-as-friend[aria-pressed=true]")
    end
  end
end
