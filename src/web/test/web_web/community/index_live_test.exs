defmodule MysticWeb.Community.IndexLiveTest do
  use MysticWeb.ConnCase, async: true
  import MysticWeb.CommunityFixtures

  defp routes(entries, attrs \\ %{}) do
    %{
      {"GET", "/api/categories"} => categories(),
      {"GET", "/api/discussions"} => page(entries, attrs)
    }
  end

  test "visitors see the discussions as cards and are invited to log in to post", %{conn: conn} do
    stub_api(routes([discussion(%{"pinned" => true, "solved" => true})]))
    {:ok, view, _html} = live(conn, ~p"/community")

    card = "#discussion-why-does-range-3-stop-at-2-abcd2345"

    assert has_element?(
             view,
             "#{card} a[href='/community/discussions/why-does-range-3-stop-at-2-abcd2345']",
             "Why does range(3) stop at 2?"
           )

    assert has_element?(view, card, "Help & Questions")
    assert has_element?(view, card, "Pinned")
    assert has_element?(view, card, "Solved")
    assert has_element?(view, card, "Hugo Bernard")
    assert has_element?(view, "#results-count", "1 discussion")
    assert has_element?(view, "#login-to-post[href='/login']")
    refute has_element?(view, "#new-discussion")
    # le filtre « suivies » n'est proposé qu'aux membres
    refute has_element?(view, "#filters_filter option[value='following']")
  end

  test "search, category, filter and sort are kept in the URL (push_patch)", %{conn: conn} do
    user = user_fixture()

    stub_api(
      Map.merge(member_routes(user), routes([discussion()], %{"total" => 23, "total_pages" => 3}))
    )

    {:ok, view, _html} = conn |> log_in() |> live(~p"/community")

    assert has_element?(view, "#new-discussion[href='/community/new']")
    assert has_element?(view, "#pagination-next[href='/community?page=2']")

    view
    |> form("#filters",
      filters: %{q: "range", category: "help-questions", filter: "following", sort: "helpful"}
    )
    |> render_change()

    assert_patch(
      view,
      ~p"/community?category=help-questions&filter=following&q=range&sort=helpful"
    )

    assert_receive {:api,
                    %{
                      path: "/api/discussions",
                      query: %{
                        "q" => "range",
                        "category" => "help-questions",
                        "filter" => "following",
                        "sort" => "helpful"
                      }
                    }}
  end

  test "reads the URL and drops unknown values", %{conn: conn} do
    stub_api(routes([discussion()], %{"page" => 2, "total_pages" => 2}))

    {:ok, view, _html} =
      live(
        conn,
        ~p"/community?category=dark-arts&filter=following&sort=solved&q=%20loops%20&page=2"
      )

    assert_receive {:api, %{path: "/api/discussions", query: query}}
    # visiteur : pas de filtre « suivies »
    assert query == %{"q" => "loops", "page" => "2"}
    assert has_element?(view, "#pagination-prev[href='/community?q=loops']")
  end

  test "empty, filtered-empty and unavailable states", %{conn: conn} do
    stub_api(routes([]))
    {:ok, view, _html} = live(conn, ~p"/community")
    assert has_element?(view, "#community-empty", "No discussion yet")

    {:ok, view, _html} = live(conn, ~p"/community?filter=solved")
    assert has_element?(view, "#community-empty", "No discussion matches these filters")
    assert has_element?(view, "#community-empty a[href='/community']", "Clear filters")

    user = user_fixture()

    stub_api(
      Map.merge(member_routes(user), %{
        {"GET", "/api/categories"} => categories(),
        {"GET", "/api/discussions"} => {503, %{"error" => "blocks_unavailable"}}
      })
    )

    {:ok, view, _html} = conn |> log_in() |> live(~p"/community")
    assert has_element?(view, "#community-unavailable", "blocked members")
  end

  test "a reply in a followed discussion: announced by the notification center's toast, not by a banner",
       %{conn: conn} do
    user = user_fixture()
    id = uuid()

    notification = %{
      "id" => id,
      "category" => "community",
      "kind" => "community_reply",
      "actor" => %{"id" => uuid(), "display_name" => "Hugo Bernard", "username" => "hugo_bernard"},
      "params" => %{"slug" => "study-group-abcd2345", "title" => "Study group"},
      "subject" => %{"type" => "discussion", "id" => "study-group-abcd2345"},
      "count" => 1,
      "read" => false
    }

    stub_api(
      member_routes(user)
      |> Map.merge(routes([discussion()]))
      |> Map.put({"GET", "/api/me/notifications/#{id}"}, %{"notification" => notification})
    )

    {:ok, view, _html} = conn |> log_in() |> live(~p"/community")

    MlShared.Events.broadcast(
      "user:#{user["id"]}",
      {:community_reply, "study-group-abcd2345", "Study group"}
    )

    refute has_element?(view, "#community-live")

    MlShared.Events.broadcast(
      "user:#{user["id"]}",
      {:notifications_changed, user["id"], %{"id" => id, "category" => "community"}}
    )

    assert has_element?(
             view,
             "#notification-toasts[aria-live='polite'] #notification-toast",
             "Hugo Bernard replied in “Study group”"
           )

    assert has_element?(
             view,
             "#notification-toast-link[href='/notifications?open=#{id}']"
           )
  end
end
