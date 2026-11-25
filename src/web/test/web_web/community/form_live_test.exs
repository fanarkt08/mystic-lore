defmodule MysticWeb.Community.FormLiveTest do
  use MysticWeb.ConnCase, async: true
  import MysticWeb.CommunityFixtures

  setup do
    user = user_fixture()
    %{user: user, routes: Map.put(member_routes(user), {"GET", "/api/categories"}, categories())}
  end

  test "signed-out visitors are sent to the login page", %{conn: conn} do
    for path <- ["/community/new", "/community/discussions/some-slug/edit"] do
      assert {:error, {:redirect, %{to: "/login?return_to=" <> _}}} = live(conn, path)
    end
  end

  test "new discussion: only the categories the member may post in; published then shown", %{
    conn: conn,
    routes: routes
  } do
    created = discussion(%{"slug" => "my-question-abcd2345"})
    stub_api(Map.put(routes, {"POST", "/api/discussions"}, {201, %{"discussion" => created}}))
    {:ok, view, _html} = conn |> log_in() |> live(~p"/community/new")

    refute has_element?(view, "#discussion_category option[value='announcements']")
    assert has_element?(view, "#discussion_category option[value='help-questions']")

    view
    |> form("#discussion-form",
      discussion: %{category: "help-questions", title: "My question", body: "How do loops work?"}
    )
    |> render_submit()

    assert_received {:api,
                     %{
                       method: "POST",
                       path: "/api/discussions",
                       body: %{
                         "category" => "help-questions",
                         "title" => "My question",
                         "body" => "How do loops work?"
                       }
                     }}

    assert_redirect(view, ~p"/community/discussions/my-question-abcd2345")
  end

  test "service validation errors and the rate limit are shown on the form", %{
    conn: conn,
    routes: routes
  } do
    errors = %{"title" => ["should be at least 5 character(s)"], "category" => ["is invalid"]}

    stub_api(
      Map.put(routes, {"POST", "/api/discussions"}, fn _conn, body ->
        if body["title"] == "Hey",
          do: {422, %{"error" => "invalid", "errors" => errors}},
          else: {429, %{"error" => "rate_limited"}}
      end)
    )

    {:ok, view, _html} = conn |> log_in() |> live(~p"/community/new")

    view
    |> form("#discussion-form",
      discussion: %{category: "off-topic", title: "Hey", body: "Too short title"}
    )
    |> render_submit()

    assert has_element?(view, "#discussion-form", "should be at least 5 characters")
    assert has_element?(view, "#discussion_body", "Too short title")

    view
    |> form("#discussion-form",
      discussion: %{category: "off-topic", title: "Hello there", body: "Ten posts already"}
    )
    |> render_submit()

    assert render(view) =~ "up to 10 posts every 10 minutes"
  end

  test "edit: only while the service allows it", %{conn: conn, routes: routes, user: user} do
    slug = "why-does-range-3-stop-at-2-abcd2345"
    mine = discussion(%{"author" => author(user["id"], "Léa Moreau"), "can_edit" => true})

    stub_api(
      Map.merge(routes, %{
        {"GET", "/api/discussions/#{slug}"} => thread(mine, []),
        {"PATCH", "/api/discussions/#{slug}"} => %{"discussion" => mine}
      })
    )

    {:ok, view, _html} = conn |> log_in() |> live(~p"/community/discussions/#{slug}/edit")
    refute has_element?(view, "#discussion_category")

    view
    |> form("#discussion-form",
      discussion: %{title: "Range explained", body: "Counting starts at zero."}
    )
    |> render_submit()

    assert_received {:api,
                     %{
                       method: "PATCH",
                       body:
                         %{"title" => "Range explained", "body" => "Counting starts at zero."} =
                           body
                     }}

    refute Map.has_key?(body, "category")
    assert_redirect(view, ~p"/community/discussions/#{slug}")

    # délai dépassé (ou autre auteur) : retour à la discussion avec une explication
    stub_api(
      Map.put(
        routes,
        {"GET", "/api/discussions/#{slug}"},
        thread(%{mine | "can_edit" => false}, [])
      )
    )

    assert {:error, {:live_redirect, %{to: to, flash: %{"error" => message}}}} =
             conn |> log_in() |> live(~p"/community/discussions/#{slug}/edit")

    assert to == "/community/discussions/#{slug}"
    assert message =~ "30 minutes"
  end
end
