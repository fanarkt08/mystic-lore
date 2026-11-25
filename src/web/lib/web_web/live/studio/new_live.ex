defmodule MysticWeb.Studio.NewLive do
  @moduledoc "New studio project from its brief (title, objectives, audience and level, duration, category, cover)."
  use MysticWeb, :live_view
  import MysticWeb.Studio.Brief

  @defaults %{
    "level" => "beginner",
    "category" => "creative",
    "cover" => "forest",
    "duration_minutes" => "30"
  }

  @impl true
  def mount(_params, _session, socket) do
    form = to_form(@defaults, as: :brief)
    {:ok, assign(socket, page_title: gettext("New project"), form: form)}
  end

  @impl true
  def handle_event("create", %{"brief" => params}, socket) do
    case Api.post(socket, :studio, "/api/projects", json: payload(params)) do
      {:ok, %{"project" => %{"id" => id}}} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Project created."))
         |> push_navigate(to: ~p"/studio/#{id}?step=outline")}

      error ->
        errors = Api.form_errors(error, fields())

        socket =
          if errors == [],
            do: put_flash(socket, :error, MysticWeb.StudioComponents.error_message(error)),
            else: socket

        {:noreply,
         assign(socket, form: to_form(params, as: :brief, errors: errors, action: :validate))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:studio}
    >
      <div class="mx-auto max-w-3xl space-y-8">
        <.link navigate={~p"/studio"} class="link text-sm">← {gettext("Studio")}</.link>
        <.page_header eyebrow={gettext("Step 1 of 5")} title={gettext("A new project")}>
          {gettext(
            "The brief guides everything that follows, including the AI drafts. You can change it at any time."
          )}
        </.page_header>
        <.form for={@form} id="new-project-form" phx-submit="create" class="card space-y-5">
          <.brief_fields form={@form} />
          <.button type="submit" id="create-project" phx-disable-with={gettext("Creating…")}>{gettext(
            "Create the project"
          )}</.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
