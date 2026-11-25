defmodule MysticWeb.ErrorHTMLTest do
  use MysticWeb.ConnCase, async: true
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders a themed 404 page" do
    html = render_to_string(MysticWeb.ErrorHTML, "404", "html", [])
    assert html =~ "This page wandered off the map"
    assert html =~ "/assets/css/app.css"
  end

  test "renders a themed 500 page" do
    assert render_to_string(MysticWeb.ErrorHTML, "500", "html", []) =~ "A spell went wrong"
  end

  test "unknown routes answer the themed 404", %{conn: conn} do
    assert html_response(get(conn, "/nowhere"), 404) =~ "This page wandered off the map"
  end
end
