defmodule MysticWeb.MultiplayerFixtures do
  @moduledoc "Fictional multiplayer payloads."

  def player(id, name),
    do: %{"id" => id, "username" => String.downcase(name), "display_name" => name, "bio" => ""}

  def lobby_summary(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "lobby-1",
        "title" => "Relais du soir",
        "visibility" => "open",
        "requires_approval" => false,
        "max_players" => 4,
        "member_count" => 2,
        "status" => "waiting",
        "starts_at" => nil,
        "host" => player("host-id", "Hugo Bernard"),
        "inserted_at" => "2026-11-23T10:00:00Z"
      },
      attrs
    )
  end

  def member(user, attrs \\ %{}) do
    Map.merge(
      %{
        "user" => user,
        "host" => false,
        "ready" => false,
        "connection" => "online",
        "joined_at" => "2026-11-23T10:00:00Z"
      },
      attrs
    )
  end

  @doc "A lobby detail as seen by the caller (`role`), with optional host tools and match."
  def lobby_detail(lobby, members, attrs \\ %{}) do
    Map.merge(
      %{
        "lobby" => Map.put(lobby, "member_count", length(members)),
        "role" => "player",
        "members" => members,
        "requests" => [],
        "invites" => [],
        "links" => [],
        "my_invite_id" => nil,
        "match" => nil
      },
      attrs
    )
  end

  def match(players, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "match-1",
        "status" => "active",
        "reason" => nil,
        "players" => players,
        "current_player" => hd(players)["id"],
        "attempts" => [],
        "max_attempts" => 6,
        "attempts_left" => 6,
        "absent" => [],
        "my_hints" => [],
        "secret" => nil,
        "started_at" => "2026-11-23T10:05:00Z",
        "finished_at" => nil,
        "xp_reward" => 50,
        "my_reward" => nil
      },
      attrs
    )
  end

  def attempt(n, user_id, sequence, marks) do
    %{
      "n" => n,
      "user_id" => user_id,
      "sequence" => sequence,
      "marks" => marks,
      "hits" => Enum.count(marks, &(&1 == "hit")),
      "present" => Enum.count(marks, &(&1 == "present"))
    }
  end

  def chat_message(id, user, body) do
    %{
      "id" => id,
      "lobby_id" => "lobby-1",
      "user_id" => user["id"],
      "user" => user,
      "body" => body,
      "inserted_at" => "2026-11-23T10:06:00Z"
    }
  end
end
