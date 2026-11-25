defmodule MysticWeb.ConnCase do
  @moduledoc """
  Test case for controllers and LiveViews. The other services are stubbed with `MysticWeb.ApiStub`
  (`Req.Test`); signed-in pages use `log_in/1` + `member_routes/1`.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MysticWeb.Endpoint
      use MysticWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import MysticWeb.ConnCase
      import MysticWeb.ApiStub
      import MysticWeb.Fixtures
    end
  end

  setup do
    # A distinct client IP per test isolates the in-memory rate limiter (controllers read `remote_ip`, LiveViews
    # the connection's `peer_data`).
    ip = {10, :rand.uniform(250), :rand.uniform(250), :rand.uniform(250)}

    conn =
      %{Phoenix.ConnTest.build_conn() | remote_ip: ip}
      |> Plug.Test.put_peer_data(%{address: ip, port: 4000, ssl_cert: nil})

    {:ok, conn: conn, ip: ip}
  end

  @doc "A fictional member (private shape of accounts) with a unique id."
  def user_fixture(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => uuid(),
        "username" => "lea_moreau",
        "display_name" => "Léa Moreau",
        "bio" => "Apprentice botanist who talks to trees.",
        "email" => "lyra@mysticlore.test",
        "confirmed" => true,
        "role" => "user",
        "inserted_at" => "2026-11-01T10:00:00Z"
      },
      attrs
    )
  end

  def member_fixture(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => uuid(),
        "username" => "hugo_bernard",
        "display_name" => "Hugo Bernard",
        "bio" => ""
      },
      attrs
    )
  end

  @doc "Profile of a member as accounts filters it for a reader (`details` nil when hidden)."
  def profile_fixture(member, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => member["id"],
        "username" => member["username"],
        "display_name" => member["display_name"],
        "avatar" => member["avatar"],
        "cover" => nil,
        "visibility" => "members",
        "details" => %{"bio" => member["bio"], "pronouns" => nil, "interests" => []},
        "academy_record" => true
      },
      attrs
    )
  end

  def uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> to_string()
  end

  @doc "Stores an accounts session token in the cookie session."
  def log_in(conn, token \\ "session-token"),
    do: Phoenix.ConnTest.init_test_session(conn, %{"session_token" => token})

  @doc """
  Routes every signed-in page needs: session resolution, unread counters (social) and the bell count of the
  notification center.
  """
  def member_routes(user, unread \\ %{"messages" => 0, "friend_requests" => 0}) do
    %{
      {"GET", "/api/sessions/current"} => %{"user" => user},
      {"GET", "/api/me/unread"} => unread,
      {"GET", "/api/me/notifications/unread-count"} => %{"unread" => 0}
    }
  end
end
