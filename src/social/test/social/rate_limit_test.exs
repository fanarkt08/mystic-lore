defmodule MlSocial.RateLimitTest do
  use MlSocialWeb.ConnCase, async: true
  alias MlSocial.RateLimit

  # instant arbitraire en début de fenêtre (heure pleine) : les deux fenêtres commencent ensemble
  @t0 1_800_000_000_000 - rem(1_800_000_000_000, 3_600_000)

  test "20 messages par 10 s : le 21e est refusé avec le délai restant, refusé = non compté" do
    me = uuid()
    for i <- 0..19, do: assert(:ok = RateLimit.hit(me, @t0 + i * 100))

    assert {:error, {:rate_limited, 8}} = RateLimit.hit(me, @t0 + 2_000)
    assert {:error, {:rate_limited, 1}} = RateLimit.hit(me, @t0 + 9_500)
    # fenêtre suivante : de nouveau permis
    assert :ok = RateLimit.hit(me, @t0 + 10_000)
    # un autre membre n'est pas concerné
    assert :ok = RateLimit.hit(uuid(), @t0 + 2_000)
  end

  test "300 messages par heure, même à un rythme permis par la fenêtre courte" do
    me = uuid()
    # 15 messages toutes les 10 s pendant 200 s : 300 envois acceptés
    for i <- 0..299, do: assert(:ok = RateLimit.hit(me, @t0 + div(i, 15) * 10_000 + rem(i, 15)))

    at = @t0 + 200_000
    assert {:error, {:rate_limited, seconds}} = RateLimit.hit(me, at)
    assert seconds == 3_400
    assert :ok = RateLimit.hit(me, @t0 + 3_600_000)
  end

  test "API : 429 rate_limited avec retry_after et l'en-tête retry-after ; rien n'est inséré" do
    [a, b] = [uuid(), uuid()]
    conversation = conversation_between(a, b)
    path = "/api/conversations/#{conversation.id}/messages"

    # fenêtres fixes : 41 envois rapides en touchent au plus deux, l'une en reçoit donc 21 au moins
    {sent, conn} =
      Enum.reduce_while(1..41, {0, nil}, fn i, {sent, _} ->
        conn = api(:post, path, a, %{body: "flood #{i}"})
        if conn.status == 201, do: {:cont, {sent + 1, conn}}, else: {:halt, {sent, conn}}
      end)

    assert %{"error" => "rate_limited", "retry_after" => seconds} = json_response(conn, 429)
    assert sent in 20..40
    assert seconds in 1..10
    assert get_resp_header(conn, "retry-after") == [Integer.to_string(seconds)]

    assert %{"entries" => entries} = api(:get, path, b) |> json_response(200)
    assert length(entries) == min(sent, 30)
    # l'autre membre écrit toujours
    assert api(:post, path, b, %{body: "calm down"}) |> json_response(201)
  end
end
