defmodule MysticWeb.AdminFixtures do
  @moduledoc "Fictional staff payloads."
  import Plug.Conn, only: [get_req_header: 2]
  alias MysticWeb.ConnCase

  def staff(role, attrs \\ %{}),
    do:
      ConnCase.user_fixture(
        Map.merge(
          %{"role" => role, "username" => "theo_garnier", "display_name" => "Théo Garnier"},
          attrs
        )
      )

  def person(id, username),
    do: %{"id" => id, "username" => username, "display_name" => String.capitalize(username)}

  @stats %{
    "accounts" => %{
      "members" => 6,
      "new_7d" => 1,
      "confirmed" => 6,
      "restricted" => 0,
      "open_appeals" => 2,
      "open_incidents" => 1,
      "sanctions_7d" => 3
    },
    "learning" => %{"enrollments" => 12, "lessons_completed_7d" => 9, "xp_7d" => 340},
    "billing" => %{
      "active_subscriptions" => %{"premium" => 1, "vip" => 1},
      "past_due_subscriptions" => 0,
      "revenue_month_cents" => 3600,
      "currency" => "usd",
      "failed_webhook_events" => 0
    },
    "social" => %{"messages_7d" => 42, "open_reports" => 3},
    "community" => %{"discussions_7d" => 4, "replies_7d" => 11, "open_reports" => 1},
    "multiplayer" => %{"open_lobbies" => 2, "matches_7d" => 5},
    "studio" => %{"review_queue" => 1, "failed_generations_24h" => 0}
  }

  @doc "Stubs `GET /api/admin/stats` of every service, `down` listing those that don't answer."
  def stats_route(down \\ []) do
    test = self()

    fn conn, _body ->
      [service] = get_req_header(conn, "x-ml-service")
      send(test, {:stats_call, service})
      if service in down, do: :unavailable, else: %{"stats" => Map.fetch!(@stats, service)}
    end
  end

  def social_report(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "sr1",
        "target_type" => "message",
        "target_id" => "m1",
        "reason" => "harassment",
        "details" => "Insults",
        "context" => nil,
        "status" => "open",
        "reporter" => person("u-lyra", "lea_moreau"),
        "reported_user" => person("u-orion", "hugo_bernard"),
        "message" => %{"id" => "m1", "sent_at" => "2026-11-23T09:00:00Z", "removed" => false},
        "resolution" => nil,
        "inserted_at" => "2026-11-23T09:05:00Z"
      },
      attrs
    )
  end

  def community_report(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "cr1",
        "target_type" => "reply",
        "target_id" => "r1",
        "target_status" => "visible",
        "reason" => "spam",
        "details" => nil,
        "status" => "open",
        "reporter" => person("u-mika", "ines_petit"),
        "snapshot" => %{
          "title" => "Loops in the grove",
          "body" => "Buy cheap potions here",
          "author" => person("u-samira", "sarah_lefevre"),
          "discussion_slug" => "loops-in-the-grove-abcd1234",
          "status" => "visible",
          "posted_at" => "2026-11-22T09:00:00Z"
        },
        "resolution" => nil,
        "inserted_at" => "2026-11-22T10:00:00Z"
      },
      attrs
    )
  end

  def admin_page(entries, attrs \\ %{}),
    do:
      Map.merge(
        %{"entries" => entries, "page" => 1, "total_pages" => 1, "total" => length(entries)},
        attrs
      )

  def member(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "u-orion",
        "username" => "hugo_bernard",
        "display_name" => "Hugo Bernard",
        "email" => "o•••@mysticlore.test",
        "email_masked" => true,
        "role" => "user",
        "confirmed" => true,
        "restricted_until" => nil,
        "deletion_scheduled_at" => nil,
        "inserted_at" => "2026-10-01T10:00:00Z"
      },
      attrs
    )
  end

  def sanction(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "s1",
        "user_id" => "u-orion",
        "kind" => "restriction",
        "reason" => "Spamming links",
        "status" => "active",
        "ends_at" => "2026-11-24T10:00:00Z",
        "ref" => nil,
        "issued_by" => person("u-theo", "theo_garnier"),
        "inserted_at" => "2026-11-23T10:00:00Z",
        "lifted_at" => nil,
        "lifted_by" => nil,
        "lift_reason" => nil,
        "appeals" => []
      },
      attrs
    )
  end

  def member_detail(attrs \\ %{}),
    do:
      member(Map.merge(%{"bio" => "", "two_factor" => false, "sanctions" => [sanction()]}, attrs))

  def appeal(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "a1",
        "sanction_id" => "s1",
        "status" => "open",
        "body" => "Those links were course resources.",
        "decision_reason" => nil,
        "decided_at" => nil,
        "decided_by" => nil,
        "inserted_at" => "2026-11-23T11:00:00Z",
        "member" => person("u-orion", "hugo_bernard"),
        "sanction" => sanction()
      },
      attrs
    )
  end

  def incident(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "i1",
        "title" => "Lesson pages slow",
        "severity" => "high",
        "status" => "open",
        "summary" => nil,
        "created_by" => person("u-theo", "theo_garnier"),
        "resolved_by" => nil,
        "resolved_at" => nil,
        "inserted_at" => "2026-11-23T08:00:00Z",
        "updated_at" => "2026-11-23T08:00:00Z",
        "updates" => [
          %{
            "id" => "up1",
            "body" => "Members report slow lessons.",
            "status" => "open",
            "severity" => "high",
            "author" => person("u-theo", "theo_garnier"),
            "inserted_at" => "2026-11-23T08:00:00Z"
          }
        ]
      },
      attrs
    )
  end

  def audit_entry(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => 7,
        "service" => "social",
        "actor" => person("u-theo", "theo_garnier"),
        "action" => "social.report.evidence_viewed",
        "target_type" => "report",
        "target_id" => "sr1",
        "reason" => "Harassment report review",
        "metadata" => %{"message_id" => "m1"},
        "inserted_at" => "2026-11-23T09:10:00Z"
      },
      attrs
    )
  end
end
