defmodule MlAccountsWeb.NotificationEmailTest do
  @moduledoc "E-mails demandés par le centre de notifications : liste blanche, langue du membre, aucun contenu privé."
  use MlAccountsWeb.ConnCase, async: true
  import Swoosh.TestAssertions
  alias MlAccounts.{Repo, User}

  @moduletag :capture_log

  defp request(user_id, body, svc \\ "notifications") do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> MlShared.InternalToken.sign(svc, nil))
    |> put_req_header("content-type", "application/json")
    |> post("/api/internal/users/#{user_id}/notification-email", Jason.encode!(body))
  end

  defp french(user) do
    {:ok, user} = MlAccounts.update_preferences(user, %{"language" => "fr"})
    user
  end

  defp message(actor, conversation \\ Ecto.UUID.generate()) do
    %{
      "kind" => "message_received",
      "actor_id" => actor.id,
      "count" => 1,
      "params" => %{"conversation_id" => conversation, "conversation_kind" => "direct"}
    }
  end

  test "the notifications service only (403 for anyone else, nothing sent)" do
    user = user_fixture()
    actor = user_fixture(%{display_name: "Hugo Bernard"})

    for svc <- ~w(web social billing accounts) do
      assert %{"error" => "forbidden"} =
               request(user.id, message(actor), svc) |> json_response(403)
    end

    assert_no_email_sent()
  end

  test "a message e-mail names the sender, links the conversation and the settings, never the text" do
    user = user_fixture(%{display_name: "Léa Moreau"})
    actor = user_fixture(%{display_name: "Hugo Bernard"})
    conversation = Ecto.UUID.generate()
    body = message(actor, conversation) |> Map.put("text", "Meet me at the grove at 9")

    assert %{"status" => "sent"} = request(user.id, body) |> json_response(200)

    assert_email_sent(fn email ->
      assert email.subject == "Hugo Bernard sent you a message"
      assert email.to == [{"Léa Moreau", user.email}]
      assert email.text_body =~ "http://localhost:4000/messages/#{conversation}"
      assert email.text_body =~ "http://localhost:4000/settings/notifications"
      refute email.text_body =~ "grove"
      refute email.html_body
      true
    end)
  end

  test "in the member's language (fr); aggregated count; group name" do
    user = french(user_fixture(%{display_name: "Léa"}))
    actor = user_fixture(%{display_name: "Hugo Bernard"})

    assert %{"status" => "sent"} =
             request(user.id, %{message(actor) | "count" => 3}) |> json_response(200)

    assert_email_sent(fn email ->
      assert email.subject == "Hugo Bernard vous a envoyé 3 messages"
      assert email.text_body =~ "Bonjour Léa,"
      assert email.text_body =~ "Vous recevez cet e-mail selon vos réglages de notifications"
      true
    end)

    group =
      put_in(message(actor), ["params"], %{
        "conversation_id" => Ecto.UUID.generate(),
        "conversation_kind" => "group",
        "group_name" => "Révisions du soir"
      })

    assert %{"status" => "sent"} = request(user.id, group) |> json_response(200)
    assert_email_sent(subject: "Hugo Bernard a écrit dans « Révisions du soir »")
  end

  test "security e-mails say they can't be turned off; billing names the plan" do
    user = user_fixture()

    assert %{"status" => "sent"} =
             request(user.id, %{"kind" => "two_factor_disabled", "params" => %{}})
             |> json_response(200)

    assert_email_sent(fn email ->
      assert email.subject == "Two-factor authentication was turned off"
      assert email.text_body =~ "always sent"
      assert email.text_body =~ "/forgot-password"
      true
    end)

    assert %{"status" => "sent"} =
             request(user.id, %{"kind" => "payment_failed", "params" => %{"plan" => "vip"}})
             |> json_response(200)

    assert_email_sent(subject: "A payment for your VIP membership failed")
  end

  test "outside the whitelist, or invalid parameters → 422 (address change and sanctions are sent here already)" do
    user = user_fixture()

    for body <- [
          %{"kind" => "email_changed", "params" => %{}},
          %{"kind" => "sanction_issued", "params" => %{"sanction_kind" => "warning"}},
          %{"kind" => "custom_html", "params" => %{}},
          %{"kind" => "message_received", "params" => %{"conversation_id" => "../admin"}},
          %{"kind" => "community_reply", "params" => %{"slug" => "Bad Slug", "title" => "x"}},
          %{"kind" => "digest", "items" => []},
          %{"kind" => "digest", "items" => [%{"kind" => "nope"}]}
        ] do
      assert %{"error" => "invalid"} = request(user.id, body) |> json_response(422)
    end

    assert_no_email_sent()
  end

  test "unknown, unconfirmed or deleted account: refused, nothing sent" do
    actor = user_fixture()

    assert %{"error" => "not_found"} =
             request(Ecto.UUID.generate(), message(actor)) |> json_response(404)

    assert %{"error" => "not_found"} = request("not-a-uuid", message(actor)) |> json_response(404)

    unconfirmed = user_fixture(confirmed: false)

    assert %{"error" => "not_deliverable"} =
             request(unconfirmed.id, message(actor)) |> json_response(409)

    leaving =
      user_fixture()
      |> Ecto.Changeset.change(
        deletion_scheduled_at: DateTime.add(DateTime.utc_now(:second), -60)
      )
      |> Repo.update!()

    assert %{"error" => "not_deliverable"} =
             request(leaving.id, message(actor)) |> json_response(409)

    assert_no_email_sent()
  end

  test "digest: one e-mail, one line per item, a deleted actor shown as « Deleted member »" do
    user = user_fixture()
    actor = user_fixture(%{display_name: "Hugo Bernard"})

    gone =
      user_fixture() |> Ecto.Changeset.change(display_name: "Deleted member") |> Repo.update!()

    items = [
      Map.put(message(actor), "count", 2),
      %{
        "kind" => "friend_request_received",
        "actor_id" => gone.id,
        "params" => %{},
        "count" => 1
      },
      %{
        "kind" => "badge_earned",
        "params" => %{"badge_slug" => "first-spark", "badge_name" => "Première étincelle"}
      }
    ]

    assert %{"status" => "sent"} =
             request(user.id, %{"kind" => "digest", "items" => items, "total" => 25})
             |> json_response(200)

    assert_email_sent(fn email ->
      assert email.subject == "While your quiet hours were on: 25 notifications"
      assert email.text_body =~ "• Hugo Bernard sent you 2 messages"
      assert email.text_body =~ "• Deleted member sent you a friend request"
      assert email.text_body =~ "• You earned the badge “Première étincelle”"
      assert email.text_body =~ "…and 22 more."
      assert email.text_body =~ "http://localhost:4000/notifications"
      true
    end)
  end

  test "the e-mail address never comes from the request" do
    user = user_fixture()
    body = %{"kind" => "two_factor_enabled", "params" => %{}, "email" => "attacker@example.test"}
    assert %{"status" => "sent"} = request(user.id, body) |> json_response(200)
    assert_email_sent(fn email -> email.to == [{user.display_name, user.email}] end)
    assert %User{} = Repo.get!(User, user.id)
  end
end
