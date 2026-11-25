defmodule MysticWeb.Community.ShowLiveTest do
  use MysticWeb.ConnCase, async: true
  import MysticWeb.CommunityFixtures

  @slug "why-does-range-3-stop-at-2-abcd2345"
  @path "/api/discussions/#{@slug}"

  setup do
    user = user_fixture()

    %{
      user: user,
      routes: Map.put(member_routes(user), {"GET", @path}, thread(discussion(), [reply()]))
    }
  end

  defp open(conn, routes, user \\ :member) do
    stub_api(routes)
    conn = if user == :member, do: log_in(conn), else: conn
    {:ok, view, _html} = live(conn, ~p"/community/discussions/#{@slug}")
    view
  end

  test "visitors read the discussion and its replies, without actions", %{conn: conn} do
    view = open(conn, %{{"GET", @path} => thread(discussion(), [reply()])}, :visitor)

    assert has_element?(view, "h1", "Why does range(3) stop at 2?")
    assert has_element?(view, "#discussion-body", "saplings 0, 1 and 2")
    assert has_element?(view, "#reply-r-1", "Inès Petit")
    assert has_element?(view, "#replies-title", "1 reply")
    assert has_element?(view, "#votes-discussion-d-1", "2 members found this helpful")
    assert has_element?(view, "#login-to-reply a[href='/login']")
    refute has_element?(view, "#reply-form")
    refute has_element?(view, "#vote-reply-r-1")
    refute has_element?(view, "#moderation-tools")
  end

  test "XSS: posts are escaped plain text, only http(s) links become (safe) links", %{conn: conn} do
    body = """
    <script>alert("pwned")</script><img src=x onerror=alert(1)>
    javascript:alert(2) and <a href="javascript:alert(3)">click</a>
    Docs: https://example.com/grove?step=1. Trap: https://evil.example/"onmouseover="alert(4)
    """

    view =
      open(
        conn,
        %{
          {"GET", @path} =>
            thread(discussion(%{"body" => body, "title" => "<b>Bold</b> title"}), [
              reply(%{"body" => "<iframe src=//evil></iframe>"})
            ])
        },
        :visitor
      )

    html = render(view)
    refute html =~ "<script>alert"
    refute html =~ "<img src=x"
    refute html =~ "<iframe"
    refute html =~ "<b>Bold</b>"
    refute html =~ ~s(href="javascript:)
    assert html =~ "&lt;script&gt;alert(&quot;pwned&quot;)&lt;/script&gt;"
    assert has_element?(view, "h1", "<b>Bold</b> title")

    assert has_element?(
             view,
             ~s(#discussion-body a[href="https://example.com/grove?step=1"][rel="nofollow ugc noopener noreferrer"][target="_blank"])
           )

    # le guillemet termine l'URL : aucun attribut injecté
    assert has_element?(view, ~s(#discussion-body a[href="https://evil.example/"]))
    refute has_element?(view, "#discussion-body a[onmouseover]")
    assert view |> element("#discussion-body") |> render() =~ "&quot;onmouseover=&quot;alert(4)"
  end

  test "helpful vote toggles between PUT and DELETE", %{conn: conn, routes: routes} do
    routes =
      Map.merge(routes, %{
        {"PUT", "/api/replies/r-1/vote"} => %{"voted" => true, "helpful_count" => 2},
        {"DELETE", "/api/replies/r-1/vote"} => %{"voted" => false, "helpful_count" => 1}
      })

    view = open(conn, routes)
    assert has_element?(view, "#vote-reply-r-1[aria-pressed='false']", "1")

    view |> element("#vote-reply-r-1") |> render_click()
    assert_received {:api, %{method: "PUT", path: "/api/replies/r-1/vote"}}
    assert has_element?(view, "#vote-reply-r-1[aria-pressed='true']", "2")

    view |> element("#vote-reply-r-1") |> render_click()
    assert_received {:api, %{method: "DELETE", path: "/api/replies/r-1/vote"}}
    assert has_element?(view, "#vote-reply-r-1[aria-pressed='false']", "1")
  end

  test "own posts can't be voted; follow and unfollow", %{conn: conn, routes: routes, user: user} do
    mine = discussion(%{"author" => author(user["id"], "Léa Moreau")})

    routes =
      Map.merge(routes, %{
        {"GET", @path} => thread(mine, [reply()]),
        {"PUT", @path <> "/follow"} => %{"following" => true},
        {"DELETE", @path <> "/follow"} => %{"following" => false}
      })

    view = open(conn, routes)
    refute has_element?(view, "#vote-discussion-d-1")
    assert has_element?(view, "#votes-discussion-d-1")

    view |> element("#follow") |> render_click()
    assert has_element?(view, "#unfollow[aria-pressed='true']")
    view |> element("#unfollow") |> render_click()
    assert has_element?(view, "#follow")
    assert_received {:api, %{method: "DELETE", path: "/api/discussions/" <> _}}
  end

  test "posting a reply; validation and rate-limit errors are shown", %{
    conn: conn,
    routes: routes
  } do
    test = self()

    routes =
      Map.put(routes, {"POST", @path <> "/replies"}, fn _conn, body ->
        send(test, {:posted, body})

        case body["body"] do
          "x" ->
            {422,
             %{
               "error" => "invalid",
               "errors" => %{"body" => ["should be at least 2 character(s)"]}
             }}

          "spam" ->
            {429, %{"error" => "rate_limited"}}

          _ ->
            {201, %{"reply" => reply(%{"id" => "r-2"})}}
        end
      end)

    view = open(conn, routes)

    view |> form("#reply-form", reply: %{body: "x"}) |> render_submit()
    assert has_element?(view, "#reply-form", "should be at least 2 characters")

    view |> form("#reply-form", reply: %{body: "spam"}) |> render_submit()
    assert render(view) =~ "up to 10 posts every 10 minutes"

    view |> form("#reply-form", reply: %{body: "Thanks, it works!"}) |> render_submit()
    assert_received {:posted, %{"body" => "Thanks, it works!"}}
    assert render(view) =~ "Reply posted."
  end

  test "report a reply with a reason", %{conn: conn, routes: routes} do
    view = open(conn, Map.put(routes, {"POST", "/api/reports"}, {201, %{"id" => "rep-1"}}))

    view |> element("#report-reply-r-1") |> render_click()
    assert has_element?(view, "#report-panel", "Report this reply")

    view
    |> form("#report-form", report: %{reason: "harassment", details: "Rude"})
    |> render_submit()

    assert_received {:api,
                     %{
                       method: "POST",
                       path: "/api/reports",
                       body: %{
                         "target_type" => "reply",
                         "target_id" => "r-1",
                         "reason" => "harassment",
                         "details" => "Rude"
                       }
                     }}

    refute has_element?(view, "#report-panel")
    assert render(view) =~ "Report sent"

    # déjà signalé : message clair
    stub_api(Map.put(routes, {"POST", "/api/reports"}, {409, %{"error" => "already_reported"}}))
    view |> element("#report-discussion-d-1") |> render_click()
    view |> form("#report-form", report: %{reason: "spam"}) |> render_submit()
    assert render(view) =~ "You already reported this"
  end

  test "blocking the author of a reply calls social and hides their posts", %{
    conn: conn,
    routes: routes
  } do
    view = open(conn, Map.put(routes, {"POST", "/api/blocks"}, {204, nil}))

    view |> element("#block-reply-r-1") |> render_click()

    assert_received {:api,
                     %{method: "POST", path: "/api/blocks", body: %{"user_id" => "author-2"}}}

    # le service filtre aussi ; même s'il renvoyait encore la réponse, elle reste masquée
    refute has_element?(view, "#reply-r-1")
    assert render(view) =~ "Member blocked"
  end

  test "blocking the author of the discussion leaves the page", %{conn: conn, routes: routes} do
    view = open(conn, Map.put(routes, {"POST", "/api/blocks"}, {204, nil}))
    view |> element("#block-discussion-d-1") |> render_click()
    assert_redirect(view, ~p"/community")
  end

  test "the author of the discussion marks a solution", %{conn: conn, routes: routes, user: user} do
    mine = discussion(%{"author" => author(user["id"], "Léa Moreau"), "can_edit" => true})

    routes =
      Map.merge(routes, %{
        {"GET", @path} => thread(mine, [reply()]),
        {"PUT", @path <> "/solution"} => %{"solution_reply_id" => "r-1"}
      })

    view = open(conn, routes)
    assert has_element?(view, "#edit-discussion[href='/community/discussions/#{@slug}/edit']")
    view |> element("#solution-r-1") |> render_click()

    assert_received {:api,
                     %{
                       method: "PUT",
                       path: "/api/discussions/" <> _,
                       body: %{"reply_id" => "r-1"}
                     }}

    # pour un autre membre, pas de bouton
    view = open(conn, Map.put(routes, {"GET", @path}, thread(discussion(), [reply()])))
    refute has_element?(view, "#solution-r-1")
  end

  test "moderation tools only for the staff role; hiding asks for a reason", %{
    conn: conn,
    routes: routes
  } do
    view = open(conn, routes)
    refute has_element?(view, "#moderation-tools")
    refute has_element?(view, "#mod-hide-r-1")

    staff = user_fixture(%{"role" => "moderator", "username" => "theo_garnier"})

    routes =
      Map.merge(routes, member_routes(staff))
      |> Map.merge(%{
        {"GET", "/api/categories"} => categories(),
        {"POST", "/api/moderation/discussions/d-1"} => {204, nil},
        {"POST", "/api/moderation/replies/r-1"} => {403, %{"error" => "forbidden"}}
      })

    view = open(conn, routes)
    assert has_element?(view, "#moderation-tools")
    assert has_element?(view, "#move-category option[value='off-topic']")

    view |> element("#mod-hide-d-1") |> render_click()
    assert has_element?(view, "#moderation-panel", "Hide this post")
    view |> form("#moderation-form", moderation: %{reason: "Spoilers"}) |> render_submit()

    assert_received {:api,
                     %{
                       method: "POST",
                       path: "/api/moderation/discussions/d-1",
                       body: %{"action" => "hide", "reason" => "Spoilers"}
                     }}

    view |> element("#mod-lock") |> render_click()

    assert_received {:api,
                     %{path: "/api/moderation/discussions/d-1", body: %{"action" => "lock"}}}

    # le service a le dernier mot : un refus est affiché tel quel
    view |> element("#mod-remove-r-1") |> render_click()
    view |> form("#moderation-form", moderation: %{reason: "Rude"}) |> render_submit()
    assert render(view) =~ "permission"
  end

  test "locked discussions: members can't reply", %{conn: conn, routes: routes} do
    view =
      open(conn, Map.put(routes, {"GET", @path}, thread(discussion(%{"locked" => true}), [])))

    assert has_element?(view, "#discussion-locked")
    refute has_element?(view, "#reply-form")
    assert has_element?(view, "#replies-empty")
  end

  test "a new reply in this followed discussion reloads it live", %{
    conn: conn,
    routes: routes,
    user: user
  } do
    view = open(conn, routes)
    assert_received {:api, %{path: @path}}

    stub_api(
      Map.put(
        routes,
        {"GET", @path},
        thread(discussion(), [reply(), reply(%{"id" => "r-2", "body" => "Late answer"})])
      )
    )

    MlShared.Events.broadcast(
      "user:#{user["id"]}",
      {:community_reply, @slug, "Why does range(3) stop at 2?"}
    )

    assert has_element?(view, "#reply-r-2", "Late answer")
    assert has_element?(view, "#community-live #notice-#{@slug}", "New reply in this discussion.")
  end

  test "unknown discussion: 404; service down: unavailable state", %{conn: conn} do
    stub_api(%{{"GET", "/api/discussions/nope"} => {404, %{"error" => "not_found"}}})
    assert_error_sent 404, fn -> get(conn, ~p"/community/discussions/nope") end

    stub_api(%{{"GET", @path} => :unavailable})
    {:ok, view, _html} = live(conn, ~p"/community/discussions/#{@slug}")
    assert has_element?(view, "#discussion-unavailable")
  end
end
