defmodule MysticWeb.HelpLive do
  @moduledoc """
  Help center (`/help`, content in `MysticWeb.Help`): questions by topic and a search that works without
  JavaScript (a plain `GET /help?q=…` filtered on the server); once the page is live, the form patches the URL.
  """
  use MysticWeb, :live_view
  alias MysticWeb.Help

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: gettext("Help center"))}

  @impl true
  def handle_params(params, _uri, socket) do
    q = Help.query(params["q"])
    {:noreply, assign(socket, q: q, results: if(q == "", do: nil, else: Help.search(q)))}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    q = Help.query(q)
    to = if q == "", do: ~p"/help", else: ~p"/help?#{[q: q]}"
    {:noreply, push_patch(socket, to: to)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      current_path={@current_path}
    >
      <div class="space-y-8">
        <.page_header eyebrow={gettext("Help")} title={gettext("Help center")}>
          {gettext("Answers about your account, lessons, membership, messages and personal data.")}
        </.page_header>

        <form
          id="help-search"
          class="help-search"
          method="get"
          action={~p"/help"}
          role="search"
          phx-submit="search"
        >
          <label for="help-q" class="label">{gettext("Search the help")}</label>
          <div class="flex flex-wrap gap-2">
            <input
              type="search"
              id="help-q"
              name="q"
              value={@q}
              maxlength={Help.max_query()}
              class="input min-w-0 flex-1"
              placeholder={gettext("For example: password, cancel, export")}
              autocomplete="off"
            />
            <button type="submit" class="btn btn-primary" id="help-submit">
              <.icon name="hero-magnifying-glass" /> {gettext("Search")}
            </button>
          </div>
        </form>

        <%!-- une seule zone de statut, présente avant toute recherche : son texte change, elle est annoncée --%>
        <div class="space-y-4">
          <h2 :if={@results} id="help-results-title" class="text-2xl">{gettext("Results")}</h2>
          <p
            id="help-results-status"
            role="status"
            aria-live="polite"
            class={if(@results, do: "text-muted", else: "sr-only")}
          >
            {@results &&
              ngettext(
                "%{count} answer for « %{q} »",
                "%{count} answers for « %{q} »",
                length(@results),
                q: @q
              )}
          </p>
        </div>
        <%= if @results do %>
          <section id="help-results" aria-labelledby="help-results-title" class="space-y-4">
            <.empty_state
              :if={@results == []}
              id="help-no-result"
              icon="hero-magnifying-glass"
              title={gettext("No answer matches your search")}
            >
              {gettext("Try other words, browse the topics, or ask the team.")}
              <:actions>
                <.button navigate={~p"/help"} variant="secondary">{gettext("All topics")}</.button>
                <.button navigate={~p"/contact"}>{gettext("Contact us")}</.button>
              </:actions>
            </.empty_state>
            <ul :if={@results != []} class="space-y-3">
              <li :for={e <- @results} id={"help-result-#{e.id}"} class="card space-y-2">
                <p class="eyebrow">{Help.topic_label(e.topic)}</p>
                <h3 class="text-xl">{e.question}</h3>
                <p class="text-muted">{e.answer}</p>
                <.help_links links={e.links} />
              </li>
            </ul>
          </section>
        <% else %>
          <nav id="help-topics" aria-label={gettext("Help topics")}>
            <ul class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
              <li :for={{key, label, icon} <- Help.topics()}>
                <a href={"#topic-#{key}"} class="help-topic" id={"help-topic-#{key}"}>
                  <.icon name={icon} class="size-5 text-magic" />
                  <span>{label}</span>
                </a>
              </li>
            </ul>
          </nav>
          <section
            :for={{key, label, _icon} <- Help.topics()}
            id={"topic-#{key}"}
            class="space-y-3"
            aria-labelledby={"topic-#{key}-title"}
          >
            <h2 id={"topic-#{key}-title"} class="text-3xl">{label}</h2>
            <details
              :for={e <- Enum.filter(Help.entries(), &(&1.topic == key))}
              id={"help-#{e.id}"}
              class="faq"
            >
              <summary>{e.question}</summary>
              <div class="space-y-2">
                <p class="text-muted">{e.answer}</p>
                <.help_links links={e.links} />
              </div>
            </details>
          </section>
        <% end %>

        <section id="help-contact" class="cta-band" aria-labelledby="help-contact-title">
          <h2 id="help-contact-title" class="text-3xl">{gettext("Didn't find your answer?")}</h2>
          <p class="max-w-xl text-muted">
            {gettext(
              "Write to the team with the contact form. You'll get an acknowledgement by e-mail, then the answer at the same address; we can't promise a response time."
            )}
          </p>
          <div class="flex flex-wrap gap-2">
            <.button navigate={~p"/contact"} id="help-contact-link">{gettext("Contact us")}</.button>
            <.button navigate={~p"/legal"} variant="secondary">{gettext("Legal information")}</.button>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :links, :list, required: true

  defp help_links(assigns) do
    ~H"""
    <ul :if={@links != []} class="flex flex-wrap gap-x-4 gap-y-1">
      <li :for={{label, path} <- @links}>
        <.link navigate={path} class="help-link">{label} →</.link>
      </li>
    </ul>
    """
  end
end
