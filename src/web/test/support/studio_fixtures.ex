defmodule MysticWeb.StudioFixtures do
  @moduledoc "Fictional studio and credit payloads."

  def studio_project(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "p1",
        "owner_id" => "owner-1",
        "role" => "owner",
        "title" => "Le Jardin au clair de lune",
        "summary" => "Grow a moonlit garden.",
        "description" => "",
        "objectives" => ["Read a loop"],
        "prerequisites" => [],
        "audience" => "Curious beginners",
        "level" => "beginner",
        "duration_minutes" => 25,
        "category" => "coding",
        "cover" => "forest",
        "status" => "draft",
        "lock_version" => 4,
        "content_revision" => 9,
        "review" => nil,
        "publication" => nil,
        "attestations" => nil,
        "submitted_at" => nil,
        "updated_at" => "2026-11-23T10:00:00Z",
        "collaborators" => [
          %{"user_id" => "ines-1", "username" => "ines_petit", "role" => "editor"}
        ],
        "images" => [],
        "modules" => [
          %{
            "id" => "m1",
            "position" => 1,
            "title" => "Seeds of Moonlight",
            "lock_version" => 2,
            "lessons" => [
              lesson("l1", "story", "The Silver Seedling", %{}),
              lesson("l2", "exercise", "Counting Petals", %{
                "question" => "What does range(3) produce?",
                "choices" => ["1, 2, 3", "0, 1, 2"],
                "answer" => 1,
                "explanation" => "It starts at 0."
              })
            ]
          },
          %{
            "id" => "m2",
            "position" => 2,
            "title" => "The Looping Beds",
            "lock_version" => 1,
            "lessons" => [
              lesson("l3", "coding", "Watering the Moonwillows", %{
                "plants" => 4,
                "starter" => "water(0)",
                "hints" => ["range(4)"]
              })
            ]
          }
        ]
      },
      attrs
    )
  end

  def lesson(id, kind, title, content) do
    %{
      "id" => id,
      "module_id" => "m1",
      "position" => 1,
      "title" => title,
      "kind" => kind,
      "body" => "Moonlight falls on the garden.",
      "xp_reward" => 10,
      "content" => content,
      "lock_version" => 3,
      "updated_at" => "2026-11-23T10:00:00Z"
    }
  end

  def ai_info(attrs \\ %{}) do
    Map.merge(
      %{
        "provider" => "demo",
        "demo" => true,
        "label" => "DEMO MODE — not a real AI",
        "configured" => true,
        "model" => nil,
        "external" => false,
        "image_generation" => true,
        "costs" => %{"outline" => 2, "lesson_draft" => 5, "feedback" => 2, "image" => 12},
        "share_drafts_with_ai" => false
      },
      attrs
    )
  end

  def credits(attrs \\ %{}) do
    Map.merge(
      %{
        "balance" => 293,
        "reserved" => 0,
        "allocation" => 300,
        "plan" => "premium",
        "period" => "2026-11",
        "resets_at" => "2026-12-01T00:00:00Z",
        "entries" => [
          %{
            "id" => "e2",
            "kind" => "reservation",
            "amount" => 2,
            "delta" => -2,
            "balance_after" => 298,
            "ref" => "studio:gen:g1",
            "reason" => "outline",
            "period" => "2026-11",
            "inserted_at" => "2026-11-23T09:00:00.000000Z"
          },
          %{
            "id" => "e1",
            "kind" => "allocation",
            "amount" => 300,
            "delta" => 300,
            "balance_after" => 300,
            "ref" => "2026-11",
            "reason" => nil,
            "period" => "2026-11",
            "inserted_at" => "2026-11-01T00:00:00.000000Z"
          }
        ],
        "page" => 1,
        "total_pages" => 1,
        "total" => 2
      },
      attrs
    )
  end

  def generation(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "g1",
        "project_id" => "p1",
        "lesson_id" => nil,
        "user_id" => "owner-1",
        "kind" => "outline",
        "status" => "pending",
        "cost" => 2,
        "credits" => "reserved",
        "provider" => "demo",
        "model" => nil,
        "demo" => true,
        "brief" => "Moon gardens",
        "result" => nil,
        "error" => nil,
        "retry_of" => nil,
        "applied_at" => nil,
        "inserted_at" => "2026-11-23T10:00:00Z"
      },
      attrs
    )
  end

  @doc "Routes of the project page (member routes included)."
  def studio_routes(member_routes, project, extra \\ %{}) do
    member_routes
    |> Map.merge(%{
      {"GET", "/api/projects/#{project["id"]}"} => %{"project" => project},
      {"GET", "/api/ai"} => ai_info(),
      {"GET", "/api/projects/#{project["id"]}/generations"} => %{"generations" => []},
      {"GET", "/api/me/credits"} => credits()
    })
    |> Map.merge(extra)
  end
end
