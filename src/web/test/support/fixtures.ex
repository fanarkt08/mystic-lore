defmodule MysticWeb.Fixtures do
  @moduledoc "Fictional service payloads."

  def adventure(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "a1",
        "slug" => "la-foret-des-murmures",
        "title" => "La Forêt des murmures",
        "summary" => "Learn loops by tending a living grove.",
        "category" => "coding",
        "difficulty" => "beginner",
        "premium" => false,
        "duration_minutes" => 25,
        "cover" => "forest"
      },
      attrs
    )
  end

  def page(entries, attrs \\ %{}),
    do:
      Map.merge(
        %{"entries" => entries, "page" => 1, "total_pages" => 1, "total" => length(entries)},
        attrs
      )

  def adventure_detail(attrs \\ %{}) do
    adventure()
    |> Map.merge(%{
      "description" => "Follow the forest spirits through two short chapters.",
      "objectives" => ["Understand range(3)", "Write a for loop"],
      "prerequisites" => [],
      "chapters" => [
        %{
          "id" => "ch1",
          "position" => 1,
          "title" => "Arrivée au bosquet",
          "lessons" => [
            %{
              "id" => "l1",
              "position" => 1,
              "title" => "Le bosquet se réveille",
              "kind" => "story",
              "xp_reward" => 10,
              "completed" => true
            },
            %{
              "id" => "l2",
              "position" => 2,
              "title" => "Rune Quiz",
              "kind" => "exercise",
              "xp_reward" => 20,
              "completed" => false
            }
          ]
        },
        %{
          "id" => "ch2",
          "position" => 2,
          "title" => "Le bosquet des boucles",
          "lessons" => [
            %{
              "id" => "l3",
              "position" => 1,
              "title" => "Le bosquet des boucles",
              "kind" => "coding",
              "xp_reward" => 40,
              "completed" => false
            }
          ]
        }
      ],
      "access" => "open",
      "enrolled" => false,
      "progress" => nil,
      "resume_lesson_id" => nil
    })
    |> Map.merge(attrs)
  end

  def plans(mode \\ "local") do
    %{
      "mode" => mode,
      "plans" => [
        %{
          "key" => "free",
          "name" => "Free",
          "price_cents" => 0,
          "currency" => "usd",
          "interval" => "month",
          "features" => ["All free adventures"]
        },
        %{
          "key" => "premium",
          "name" => "Premium",
          "price_cents" => 1200,
          "currency" => "usd",
          "interval" => "month",
          "features" => ["Every premium adventure"]
        },
        %{
          "key" => "vip",
          "name" => "VIP",
          "price_cents" => 2400,
          "currency" => "usd",
          "interval" => "month",
          "features" => ["Premium + early access"]
        }
      ]
    }
  end

  def billing(user_id, attrs \\ %{}, mode \\ "local") do
    entitlements =
      Map.merge(
        %{
          "user_id" => user_id,
          "plan" => "free",
          "status" => "none",
          "current_period_end" => nil,
          "cancel_at_period_end" => false
        },
        attrs
      )

    %{"entitlements" => entitlements, "invoices" => [], "mode" => mode}
  end

  def message(id, conversation_id, sender_id, body) do
    %{
      "id" => id,
      "conversation_id" => conversation_id,
      "kind" => "text",
      "sender_id" => sender_id,
      "body" => body,
      "removed" => false,
      "hidden" => false,
      "attachment" => nil,
      "system" => nil,
      "inserted_at" => "2026-11-23T09:30:00Z"
    }
  end

  @doc "Direct conversation of `user` with `other`."
  def direct_conversation(id, user, other, attrs \\ %{}) do
    Map.merge(
      conversation(id, "direct", [member(user), member(other)])
      |> Map.put("other", other),
      attrs
    )
  end

  @doc "Group conversation owned by `owner`, with `others`."
  def group_conversation(id, owner, others, attrs \\ %{}) do
    Map.merge(
      conversation(id, "group", [member(owner, "owner") | Enum.map(others, &member/1)])
      |> Map.merge(%{"name" => "Moonlit circle", "owner_id" => owner["id"]}),
      attrs
    )
  end

  defp conversation(id, kind, members) do
    %{
      "id" => id,
      "kind" => kind,
      "name" => nil,
      "owner_id" => nil,
      "other" => nil,
      "members" => members,
      "last_message" => nil,
      "unread" => 0,
      "muted" => false,
      "muted_until" => nil,
      "read_receipts" => %{"enabled" => true, "reads" => []}
    }
  end

  defp member(user, role \\ "member"),
    do: %{
      "user" => Map.take(user, ~w(id username display_name avatar)),
      "role" => role,
      "joined_at" => "2026-11-20T10:00:00Z"
    }
end
