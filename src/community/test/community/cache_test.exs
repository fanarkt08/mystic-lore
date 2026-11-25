defmodule MlCommunity.CacheTest do
  # Le cache est global : module non asynchrone (aucun autre test ne tourne en même temps).
  use MlCommunity.DataCase, async: false
  alias MlCommunity.{Accounts, Social}

  setup do
    clear_cache()
    test = self()
    {member, other} = {uuid(), uuid()}

    # compte les appels à social et accounts (rôles)
    counting = fn blocks ->
      Req.Test.stub(MlShared.Client, fn conn ->
        send(test, {:called, conn.request_path})

        case conn.request_path do
          "/api/internal/blocks/" <> _ ->
            Req.Test.json(conn, %{"user_ids" => blocks})

          "/api/internal/users/" <> id ->
            Req.Test.json(conn, %{"user" => %{"id" => id, "role" => "user"}})
        end
      end)
    end

    counting.([])
    {:ok, member: member, other: other, counting: counting}
  end

  test "blocks are cached, and invalidated as soon as social reports a change", %{
    member: member,
    other: other,
    counting: counting
  } do
    assert {:ok, []} = Social.blocked_ids(member)
    assert {:ok, []} = Social.blocked_ids(member)
    assert_received {:called, "/api/internal/blocks/" <> _}
    refute_received {:called, _}

    # social publie {:friendship_changed, id} sur "user:<id>" quand le membre bloque ou est bloqué
    counting.([other])
    MlShared.Events.broadcast("user:" <> member, {:friendship_changed, member})
    _ = :sys.get_state(MlCommunity.Cache)

    assert {:ok, [^other]} = Social.blocked_ids(member)
    assert_received {:called, "/api/internal/blocks/" <> _}
  end

  @tag :capture_log
  test "errors are never cached; roles are cached too", %{member: member, counting: counting} do
    Req.Test.stub(MlShared.Client, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, :unavailable} = Social.blocked_ids(member)
    assert {:error, :unavailable} = Accounts.staff?(member)

    counting.([])
    assert {:ok, []} = Social.blocked_ids(member)
    assert {:ok, false} = Accounts.staff?(member)
    assert {:ok, false} = Accounts.staff?(member)
    assert_received {:called, "/api/internal/blocks/" <> _}
    assert_received {:called, "/api/internal/users/" <> _}
    refute_received {:called, _}
  end
end
