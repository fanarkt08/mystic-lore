defmodule MlNotificationsWeb.SettingsTest do
  use MlNotificationsWeb.ConnCase, async: true
  alias MlNotifications.{EmailWorker, Notification}

  @path "/api/me/notification-settings"

  defp category(settings, key), do: Enum.find(settings["categories"], &(&1["key"] == key))

  test "defaults: security and account locked on, billing e-mail on, the others in-app only" do
    me = uuid()
    assert %{"settings" => settings} = api(:get, @path, me) |> json_response(200)

    assert %{"in_app" => true, "email" => true, "locked" => ["in_app", "email"]} =
             category(settings, "security")

    assert %{"in_app" => true, "email" => true, "locked" => ["in_app", "email"]} =
             category(settings, "account")

    assert %{"in_app" => true, "email" => true, "locked" => []} = category(settings, "billing")

    for key <- ~w(messages friends community multiplayer studio learning),
        do:
          assert(%{"in_app" => true, "email" => false, "locked" => []} = category(settings, key))

    assert Enum.map(settings["categories"], & &1["key"]) ==
             ~w(security account billing messages friends community multiplayer studio learning)

    assert %{"enabled" => false, "start" => "22:00", "end" => "07:00", "time_zone" => nil} =
             settings["quiet_hours"]

    assert %{"count" => 0, "send_at" => nil} = settings["pending_digest"]
  end

  test "locked channels can't be turned off; the others are saved and returned" do
    me = uuid()

    for {category, channel} <- [
          {"security", "email"},
          {"security", "in_app"},
          {"account", "in_app"}
        ] do
      field = "channels.#{category}.#{channel}"

      assert %{"errors" => %{^field => ["is locked"]}} =
               api(:patch, @path, me, %{"channels" => %{category => %{channel => false}}})
               |> json_response(422)
    end

    assert %{"settings" => settings} =
             api(:patch, @path, me, %{
               "channels" => %{
                 "messages" => %{"email" => true},
                 "learning" => %{"in_app" => false},
                 "security" => %{"email" => true}
               }
             })
             |> json_response(200)

    assert %{"in_app" => true, "email" => true} = category(settings, "messages")
    assert %{"in_app" => false, "email" => false} = category(settings, "learning")

    for body <- [
          %{"channels" => %{"ads" => %{"email" => true}}},
          %{"channels" => %{"messages" => %{"sms" => true}}},
          %{"channels" => %{"messages" => %{"email" => "yes"}}},
          %{"channels" => "all"}
        ] do
      assert %{"error" => "invalid"} = api(:patch, @path, me, body) |> json_response(422)
    end

    # the refused changes changed nothing
    assert %{"settings" => again} = api(:get, @path, me) |> json_response(200)
    assert again["categories"] == settings["categories"]
  end

  test "a category turned off in-app creates no notification; an optional e-mail follows its own switch" do
    me = uuid()
    settings!(me, %{"channels" => %{"learning" => %{"in_app" => false, "email" => true}}})
    result = create!(attrs("badge_earned", me))
    assert %{status: "skipped", notification: nil, email: "queued"} = result
    assert Repo.aggregate(Notification, :count) == 0
    assert_enqueued(worker: EmailWorker, args: %{"user_id" => me, "kind" => "badge_earned"})
  end

  test "the e-mail preference only governs optional categories (billing access: always)" do
    me = uuid()
    settings!(me, %{"channels" => %{"billing" => %{"in_app" => false, "email" => false}}})

    assert %{status: "skipped", email: "none"} = create!(attrs("subscription_activated", me))

    # payment failure and end of membership affect access: created and e-mailed anyway
    assert %{status: "created", email: "queued"} = create!(attrs("payment_failed", me))
  end

  test "quiet hours: validated, saved with their time zone" do
    me = uuid()

    bad = [
      {%{"enabled" => true}, %{"quiet_hours.time_zone" => ["can't be blank"]}},
      {%{"time_zone" => "Mars/Olympus"},
       %{"quiet_hours.time_zone" => ["is not a known time zone"]}},
      {%{"start" => "7:00"}, %{"quiet_hours.start" => ["is invalid"]}},
      {%{"end" => "24:00"}, %{"quiet_hours.end" => ["is invalid"]}},
      {%{"start" => "08:00", "end" => "08:00"},
       %{"quiet_hours.end" => ["must differ from the start"]}},
      {%{"enabled" => "yes"}, %{"quiet_hours.enabled" => ["is invalid"]}}
    ]

    for {body, errors} <- bad do
      assert %{"error" => "invalid", "errors" => ^errors} =
               api(:patch, @path, me, %{"quiet_hours" => body}) |> json_response(422)
    end

    MlShared.Events.subscribe("user:#{me}")

    assert %{"settings" => %{"quiet_hours" => quiet}} =
             api(:patch, @path, me, %{
               "quiet_hours" => %{
                 "enabled" => true,
                 "start" => "21:30",
                 "end" => "06:45",
                 "time_zone" => "Europe/Paris"
               }
             })
             |> json_response(200)

    assert %{
             "enabled" => true,
             "start" => "21:30",
             "end" => "06:45",
             "time_zone" => "Europe/Paris"
           } =
             quiet

    assert is_boolean(quiet["active"])
    assert_receive {:notification_settings_changed, ^me}
  end
end
