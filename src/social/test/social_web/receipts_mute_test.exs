defmodule MlSocialWeb.ReceiptsMuteTest do
  use MlSocialWeb.ConnCase, async: true
  import Ecto.Query
  alias MlShared.Events
  alias MlSocial.{Member, Repo}

  setup do
    [a, b, c] = for _ <- 1..3, do: uuid()
    %{a: a, b: b, c: c, group: group!(a, [b, c])}
  end

  defp path(group, suffix \\ ""), do: "/api/conversations/#{group.id}#{suffix}"
  defp say(group, user, body), do: api(:post, path(group, "/messages"), user, %{body: body})
  defp read(group, user), do: api(:post, path(group, "/read"), user) |> response(204)

  defp receipts(group, user),
    do: (api(:get, path(group), user) |> json_response(200))["conversation"]["read_receipts"]

  defp unread(user), do: (api(:get, "/api/me/unread", user) |> json_response(200))["messages"]

  describe "accusés de lecture" do
    test "lectures des autres membres, avec la date ; en 1:1 comme en groupe", ctx do
      say(ctx.group, ctx.a, "Did you read it?") |> json_response(201)
      read(ctx.group, ctx.b)

      assert %{"enabled" => true, "reads" => [%{"user_id" => reader, "read_at" => at}]} =
               receipts(ctx.group, ctx.a)

      assert reader == ctx.b
      assert {:ok, _, 0} = DateTime.from_iso8601(at)

      direct = conversation_between(ctx.b, ctx.c)
      read(direct, ctx.c)
      assert %{"reads" => [%{"user_id" => c}]} = receipts(direct, ctx.b)
      assert c == ctx.c
    end

    test "réciprocité : qui coupe les siens ne voit plus ceux des autres, et les siens disparaissent",
         ctx do
      read(ctx.group, ctx.b)
      read(ctx.group, ctx.c)
      setting!(ctx.c, %{"read_receipts" => false})

      # a ne voit plus la lecture de c, seulement celle de b
      assert %{"enabled" => true, "reads" => [%{"user_id" => b}]} = receipts(ctx.group, ctx.a)
      assert b == ctx.b
      # c ne voit plus celles des autres
      assert %{"enabled" => false, "reads" => []} = receipts(ctx.group, ctx.c)
    end

    test "en direct : {:messages_read} seulement vers ceux qui y ont droit ; un réglage coupé prévient les membres",
         ctx do
      for user <- [ctx.a, ctx.c], do: Events.subscribe(Events.user(user))
      setting!(ctx.c, %{"read_receipts" => false})
      # le changement de réglage recharge la conversation chez ses membres
      assert_receive {:conversation_changed, id}
      assert id == ctx.group.id

      read(ctx.group, ctx.b)
      group_id = ctx.group.id
      reader = ctx.b
      assert_receive {:messages_read, ^group_id, %{"user_id" => ^reader, "read_at" => _}}
      # c a coupé les siens : il ne reçoit pas les lectures des autres
      refute_receive {:messages_read, _, _}, 50

      # et la lecture de c n'est envoyée à personne
      read(ctx.group, ctx.c)
      refute_receive {:messages_read, _, _}, 50
    end

    test "pas d'accusé entre membres qui ont un blocage", ctx do
      api(:post, "/api/blocks", ctx.b, %{user_id: ctx.c}) |> response(204)
      Events.subscribe(Events.user(ctx.c))
      read(ctx.group, ctx.b)
      refute_receive {:messages_read, _, _}, 50
      assert %{"reads" => []} = receipts(ctx.group, ctx.c)
    end
  end

  describe "sourdine" do
    test "1 h, 8 h, 24 h ou toujours ; compteur propre gardé, badge global sans elle", ctx do
      say(ctx.group, ctx.a, "one") |> json_response(201)
      say(ctx.group, ctx.a, "two") |> json_response(201)
      assert unread(ctx.b) == 2

      assert %{"errors" => %{"duration" => ["is invalid"]}} =
               api(:put, path(ctx.group, "/mute"), ctx.b, %{duration: "2h"}) |> json_response(422)

      Events.subscribe(Events.user(ctx.b))

      assert %{"conversation" => %{"muted" => true, "muted_until" => until, "unread" => 2}} =
               api(:put, path(ctx.group, "/mute"), ctx.b, %{duration: "8h"}) |> json_response(200)

      assert {:ok, until, 0} = DateTime.from_iso8601(until)
      assert_in_delta DateTime.diff(until, DateTime.utc_now()), 8 * 3600, 5
      assert_receive {:unread_changed, _}
      assert unread(ctx.b) == 0

      assert %{"conversations" => [%{"muted" => true, "unread" => 2}]} =
               api(:get, "/api/me/conversations", ctx.b) |> json_response(200)

      # toujours : muted sans date de fin
      assert %{"conversation" => %{"muted" => true, "muted_until" => nil}} =
               api(:put, path(ctx.group, "/mute"), ctx.b, %{duration: "always"})
               |> json_response(200)

      say(ctx.group, ctx.c, "three") |> json_response(201)
      assert unread(ctx.b) == 0

      # route interne pour les notifications : sourdines en cours
      assert %{"mutes" => [%{"conversation_id" => cid, "muted_until" => nil}]} =
               service_get("/api/internal/users/#{ctx.b}/mutes")

      assert cid == ctx.group.id

      assert %{"conversation" => %{"muted" => false, "muted_until" => nil}} =
               api(:delete, path(ctx.group, "/mute"), ctx.b) |> json_response(200)

      assert unread(ctx.b) == 3
      assert %{"mutes" => []} = service_get("/api/internal/users/#{ctx.b}/mutes")
    end

    test "une sourdine échue ne retire plus rien", ctx do
      api(:put, path(ctx.group, "/mute"), ctx.b, %{duration: "1h"}) |> json_response(200)
      say(ctx.group, ctx.a, "hello") |> json_response(201)
      assert unread(ctx.b) == 0

      Repo.update_all(
        from(m in Member, where: m.conversation_id == ^ctx.group.id and m.user_id == ^ctx.b),
        set: [muted_until: DateTime.add(DateTime.utc_now(), -1)]
      )

      assert unread(ctx.b) == 1

      assert %{"conversation" => %{"muted" => false}} =
               api(:get, path(ctx.group), ctx.b) |> json_response(200)
    end
  end

  defp service_get(path) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> MlShared.InternalToken.sign("web"))
    |> get(path)
    |> json_response(200)
  end
end
