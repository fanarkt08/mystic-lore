defmodule MysticWeb.ErrorHTML do
  @moduledoc "Themed error pages (rendered without layout, so they carry their own document)."
  use MysticWeb, :html

  def render("404.html", assigns) do
    error_page(
      Map.merge(assigns, %{
        code: "404",
        title: gettext("This page wandered off the map"),
        text: gettext("The page you are looking for doesn't exist, or it has moved.")
      })
    )
  end

  def render("403.html", assigns) do
    error_page(
      Map.merge(assigns, %{
        code: "403",
        title: gettext("This door is sealed"),
        text: gettext("You don't have access to this page.")
      })
    )
  end

  def render("500.html", assigns) do
    error_page(
      Map.merge(assigns, %{
        code: "500",
        title: gettext("A spell went wrong"),
        text: gettext("Something broke on our side. Please try again in a moment.")
      })
    )
  end

  def render(template, _assigns), do: Phoenix.Controller.status_message_from_template(template)

  defp error_page(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang={Gettext.get_locale(MysticWeb.Gettext)}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="color-scheme" content="dark" />
        <title>{@title} · MysticLore</title>
        <%!-- polices auto-hébergées, chargées par app.css : aucune requête vers un tiers --%>
        <link rel="stylesheet" href={~p"/assets/css/app.css"} />
      </head>
      <body>
        <a href="#main" class="skip-link">{gettext("Skip to content")}</a>
        <main id="main" class="error-page" tabindex="-1">
          <a href="/" class="flex items-center gap-2">
            <Layouts.brand_mark />
            <span class="font-display text-2xl text-ink">MysticLore</span>
          </a>
          <div class="card w-full max-w-xl space-y-4 text-center md:p-10">
            <p class="eyebrow">{gettext("Error %{code}", code: @code)}</p>
            <h1 class="text-4xl md:text-5xl">{@title}</h1>
            <p class="text-muted">{@text}</p>
            <div class="flex flex-wrap justify-center gap-2 pt-2">
              <a href="/" class="btn btn-primary">{gettext("Back to the academy")}</a>
              <a href="/adventures" class="btn btn-secondary">{gettext("Browse adventures")}</a>
            </div>
            <nav aria-label={gettext("Help")} class="error-help" id="error-help">
              <p class="text-sm text-muted">{gettext("Still stuck?")}</p>
              <ul class="flex flex-wrap justify-center gap-x-4 gap-y-1">
                <li>
                  <a href="/help" class="link" id="error-help-link">{gettext("Help center")}</a>
                </li>
                <li>
                  <a href="/contact" class="link" id="error-contact-link">{gettext("Contact us")}</a>
                </li>
              </ul>
            </nav>
          </div>
        </main>
      </body>
    </html>
    """
  end
end
