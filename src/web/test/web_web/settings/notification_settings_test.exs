defmodule MysticWeb.Settings.NotificationSettingsTest do
  @moduledoc """
  `/settings/notifications`: category × channel matrix (locked rows explained), quiet hours saved with the
  page's effective time zone; a save is announced (`role=status`) only once the center answered.
  """
  use MysticWeb.ConnCase, async: true

  @path "/api/me/notification-settings"

  defp prefs(attrs),
    do:
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

  defp settings(attrs \\ %{}) do
    locked = ~w(in_app email)

    Map.merge(
      %{
        "categories" => [
          %{"key" => "security", "in_app" => true, "email" => true, "locked" => locked},
          %{"key" => "account", "in_app" => true, "email" => true, "locked" => locked},
          %{"key" => "billing", "in_app" => true, "email" => true, "locked" => []},
          %{"key" => "messages", "in_app" => true, "email" => false, "locked" => []},
          %{"key" => "friends", "in_app" => true, "email" => false, "locked" => []},
          %{"key" => "community", "in_app" => true, "email" => false, "locked" => []},
          %{"key" => "multiplayer", "in_app" => true, "email" => false, "locked" => []},
          %{"key" => "studio", "in_app" => true, "email" => false, "locked" => []},
          %{"key" => "learning", "in_app" => true, "email" => false, "locked" => []}
        ],
        "quiet_hours" => %{
          "enabled" => false,
          "start" => "22:00",
          "end" => "07:00",
          "time_zone" => nil,
          "active" => false,
          "ends_at" => nil
        },
        "pending_digest" => %{"count" => 0, "send_at" => nil}
      },
      attrs
    )
  end

  defp open(conn, user, routes, connect_params \\ %{}) do
    stub_api(Map.merge(member_routes(user), routes))

    {:ok, view, _html} =
      conn |> log_in() |> put_connect_params(connect_params) |> live(~p"/settings/notifications")

    view
  end

  test "the section sits after Learning; locked rows say « Always » and why", %{conn: conn} do
    user = user_fixture(%{"preferences" => prefs(%{})})
    view = open(conn, user, %{{"GET", @path} => %{"settings" => settings()}})

    nav = view |> element("#settings-nav") |> render()
    assert nav =~ ~r/settings-nav-learning.*settings-nav-notifications.*settings-nav-privacy/s

    assert has_element?(view, "#channel-security-email-locked", "Always")
    assert has_element?(view, "#channel-security-in_app-locked", "Always")
    refute has_element?(view, "#channel-security-email")
    assert has_element?(view, "#channels-security-hint", "Always on, in the app and by e-mail")
    assert has_element?(view, "#channels-billing-hint", "affect your access")

    assert has_element?(view, "#channel-messages-email[type=checkbox]")
    refute has_element?(view, "#channel-messages-email[checked]")
    assert has_element?(view, "#channel-messages-in_app[checked]")

    assert has_element?(
             view,
             "label[for='channel-messages-email'] .sr-only",
             "Messages by e-mail"
           )
  end

  test "channels: every configurable cell is sent; success announced after the center answered",
       %{
         conn: conn
       } do
    user = user_fixture(%{"preferences" => prefs(%{})})
    saved = settings() |> put_in(["categories", Access.at(3), "email"], true)

    view =
      open(conn, user, %{
        {"GET", @path} => %{"settings" => settings()},
        {"PATCH", @path} => %{"settings" => saved}
      })

    assert has_element?(view, "#notification-channels-status[role='status']")
    refute has_element?(view, "#notification-channels-status", "saved")

    view
    |> form("#notification-channels-form", %{
      "channels" => %{"messages" => %{"in_app" => "true", "email" => "true"}}
    })
    |> render_submit()

    assert_received {:api, %{method: "PATCH", path: @path, body: %{"channels" => channels}}}
    assert channels["messages"] == %{"in_app" => true, "email" => true}
    # the checkboxes that stayed unchecked are sent as false, the locked cells never
    assert channels["learning"] == %{"in_app" => true, "email" => false}
    refute Map.has_key?(channels, "security")

    assert has_element?(view, "#notification-channels-status", "Notification choices saved.")
    assert has_element?(view, "#channel-messages-email[checked]")
  end

  test "a refused save shows the reason next to the matrix, nothing announced", %{conn: conn} do
    user = user_fixture(%{"preferences" => prefs(%{})})

    view =
      open(conn, user, %{
        {"GET", @path} => %{"settings" => settings()},
        {"PATCH", @path} =>
          {422,
           %{"error" => "invalid", "errors" => %{"channels.security.email" => ["is locked"]}}}
      })

    view |> form("#notification-channels-form") |> render_submit()
    assert has_element?(view, "#notification-channels-error", "is locked")
    refute has_element?(view, "#notification-channels-status", "saved")
  end

  test "quiet hours: sent with the member's explicit time zone, shown on the page", %{conn: conn} do
    user = user_fixture(%{"preferences" => prefs(%{"time_zone" => "Europe/Paris"})})

    saved =
      settings(%{
        "quiet_hours" => %{
          "enabled" => true,
          "start" => "22:30",
          "end" => "06:30",
          "time_zone" => "Europe/Paris",
          "active" => false,
          "ends_at" => nil
        }
      })

    view =
      open(conn, user, %{
        {"GET", @path} => %{"settings" => settings()},
        {"PATCH", @path} => %{"settings" => saved}
      })

    assert has_element?(view, "#quiet-time-zone", "Europe/Paris")
    assert has_element?(view, "#quiet-time-zone", "from your preferences")

    view
    |> form("#quiet-hours-form", %{
      "quiet" => %{"enabled" => "true", "start" => "22:30", "end" => "06:30"}
    })
    |> render_submit()

    assert_received {:api,
                     %{
                       method: "PATCH",
                       path: @path,
                       body: %{
                         "quiet_hours" => %{
                           "enabled" => true,
                           "start" => "22:30",
                           "end" => "06:30",
                           "time_zone" => "Europe/Paris"
                         }
                       }
                     }}

    assert has_element?(view, "#quiet-hours-status", "Quiet hours saved.")
    assert has_element?(view, "#quiet-enabled[checked]")
  end

  test "quiet hours: « auto » sends this browser's zone; errors next to their field; pending e-mails shown",
       %{conn: conn} do
    user = user_fixture(%{"preferences" => prefs(%{})})

    current =
      settings(%{
        "quiet_hours" => %{
          "enabled" => true,
          "start" => "22:00",
          "end" => "07:00",
          "time_zone" => "Europe/Paris",
          "active" => true,
          "ends_at" => "2026-11-25T06:00:00Z"
        },
        "pending_digest" => %{"count" => 2, "send_at" => "2026-11-25T06:00:00Z"}
      })

    view =
      open(
        conn,
        user,
        %{
          {"GET", @path} => %{"settings" => current},
          {"PATCH", @path} =>
            {422,
             %{
               "error" => "invalid",
               "errors" => %{"quiet_hours.end" => ["must differ from the start"]}
             }}
        },
        %{"tz" => "Asia/Tokyo"}
      )

    assert has_element?(view, "#quiet-time-zone", "Asia/Tokyo")
    assert has_element?(view, "#quiet-time-zone", "detected from this browser")
    # saved from another device with Paris: said honestly
    assert has_element?(view, "#quiet-other-zone", "Europe/Paris")
    assert has_element?(view, "#quiet-active", "15:00 JST")
    assert has_element?(view, "#quiet-pending", "2 e-mails are waiting")

    view
    |> form("#quiet-hours-form", %{
      "quiet" => %{"enabled" => "true", "start" => "08:00", "end" => "08:00"}
    })
    |> render_submit()

    assert_received {:api,
                     %{method: "PATCH", body: %{"quiet_hours" => %{"time_zone" => "Asia/Tokyo"}}}}

    assert has_element?(view, "#quiet-end-error", "must differ from the start")
    refute has_element?(view, "#quiet-hours-status", "saved")
  end

  test "the center unreachable: an honest unavailable state", %{conn: conn} do
    user = user_fixture(%{"preferences" => prefs(%{})})
    view = open(conn, user, %{{"GET", @path} => :unavailable})
    assert has_element?(view, "#notification-settings-unavailable")
    refute has_element?(view, "#notification-channels-form")
  end
end
