defmodule MysticWeb.CoreComponents do
  @moduledoc """
  Generic UI building blocks (buttons, inputs, notices, flash, icons). Styling lives in
  `assets/css/app.css` (design tokens + a few component classes) and Tailwind utilities.
  """
  use Phoenix.Component
  use Gettext, backend: MysticWeb.Gettext
  alias Phoenix.LiveView.JS

  @doc "Flash toast (`:info` is announced politely, `:error` as an alert)."
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error]
  attr :rest, :global
  slot :inner_block

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role={if @kind == :error, do: "alert", else: "status"}
      class={["toast", @kind == :error && "toast-error"]}
      {@rest}
    >
      <.icon
        name={if @kind == :error, do: "hero-exclamation-circle", else: "hero-check-circle"}
        class="size-5 shrink-0 mt-0.5"
      />
      <div class="min-w-0 flex-1">
        <p :if={@title} class="font-semibold">{@title}</p>
        <p>{msg}</p>
      </div>
      <button type="button" class="toast-close" aria-label={gettext("Dismiss")}>
        <.icon name="hero-x-mark" class="size-5" />
      </button>
    </div>
    """
  end

  @doc "Button, or a link styled as a button when `href`, `navigate` or `patch` is given."
  attr :variant, :string, default: "primary", values: ~w(primary secondary ghost danger reward)
  attr :class, :any, default: nil

  attr :rest, :global,
    include:
      ~w(href navigate patch method download name value disabled type form target rel replace)

  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns = assign(assigns, :classes, ["btn", "btn-#{assigns.variant}", assigns.class])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@classes} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <button class={@classes} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  @doc "Labelled form control with its hint and errors wired through `aria-describedby`."
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :hint, :string, default: nil
  attr :value, :any
  attr :type, :string, default: "text"
  attr :field, Phoenix.HTML.FormField, doc: "a form field, for example: @form[:email]"
  attr :errors, :list, default: []
  attr :options, :list, default: [], doc: "options for type=select"
  attr :prompt, :string, default: nil, doc: "empty first option for type=select"
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(autocomplete disabled form maxlength minlength pattern placeholder readonly
                required rows spellcheck inputmode autocapitalize autofocus min max step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn -> field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(assigns) do
    assigns = assign(assigns, :describedby, describedby(assigns))

    ~H"""
    <div class="field">
      <label :if={@label} for={@id} class="label">{@label}</label>
      <%= case @type do %>
        <% "select" -> %>
          <select
            id={@id}
            name={@name}
            class={["input", @class]}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@describedby}
            {@rest}
          >
            <option :if={@prompt} value="">{@prompt}</option>
            {Phoenix.HTML.Form.options_for_select(@options, @value)}
          </select>
        <% "textarea" -> %>
          <textarea
            id={@id}
            name={@name}
            class={["input", @class]}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@describedby}
            {@rest}
          >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
        <% _ -> %>
          <input
            type={@type}
            id={@id}
            name={@name}
            value={Phoenix.HTML.Form.normalize_value(@type, @value)}
            class={["input", @class]}
            aria-invalid={@errors != [] && "true"}
            aria-describedby={@describedby}
            {@rest}
          />
      <% end %>
      <p :if={@hint} id={"#{@id}-hint"} class="field-hint">{@hint}</p>
      <p :if={@errors != []} id={"#{@id}-error"} class="field-error">
        <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
        <span>{Enum.join(@errors, " · ")}</span>
      </p>
    </div>
    """
  end

  defp describedby(%{id: id, hint: hint, errors: errors}) do
    case Enum.reject([hint && "#{id}-hint", errors != [] && "#{id}-error"], &(!&1)) do
      [] -> nil
      ids -> Enum.join(ids, " ")
    end
  end

  @doc "Contextual message box, polite by default (use `role=\"alert\"` for errors)."
  attr :kind, :string, default: "info", values: ~w(info success danger warning reward)
  attr :title, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, default: %{role: "status"}
  slot :inner_block
  slot :actions

  def notice(assigns) do
    ~H"""
    <div class={["notice", "notice-#{@kind}", @class]} {@rest}>
      <.icon name={notice_icon(@kind)} class="size-5 shrink-0 mt-0.5" />
      <div class="min-w-0 flex-1 space-y-1">
        <p :if={@title} class="font-semibold text-ink">{@title}</p>
        <div :if={@inner_block != []}>{render_slot(@inner_block)}</div>
        <div :if={@actions != []} class="flex flex-wrap gap-2 pt-2">{render_slot(@actions)}</div>
      </div>
    </div>
    """
  end

  defp notice_icon("success"), do: "hero-check-circle"
  defp notice_icon("danger"), do: "hero-exclamation-triangle"
  defp notice_icon("warning"), do: "hero-exclamation-triangle"
  defp notice_icon("reward"), do: "hero-sparkles"
  defp notice_icon(_), do: "hero-information-circle"

  @doc "Local degraded state when a service can't be reached; « Try again » mounts the page again."
  attr :id, :string, default: nil
  attr :retry, :boolean, default: true
  slot :inner_block, required: true

  def unavailable(assigns) do
    ~H"""
    <.notice id={@id} kind="warning" title={gettext("Temporarily unavailable")} class="unavailable">
      {render_slot(@inner_block)} {gettext("Please try again in a moment.")}
      <:actions :if={@retry}>
        <button
          type="button"
          class="btn btn-secondary"
          id={@id && "#{@id}-retry"}
          phx-click="ml:retry"
          phx-disable-with={gettext("Reloading…")}
        >
          <.icon name="hero-arrow-path" /> {gettext("Try again")}
        </button>
      </:actions>
    </.notice>
    """
  end

  @doc "Page title block: optional eyebrow, display title, lead text and actions."
  attr :title, :string, required: true
  attr :eyebrow, :string, default: nil
  attr :id, :string, default: nil
  slot :inner_block
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header id={@id} class="flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
      <div class="min-w-0 space-y-2">
        <p :if={@eyebrow} class="eyebrow">{@eyebrow}</p>
        <h1 class="text-4xl md:text-5xl">{@title}</h1>
        <p :if={@inner_block != []} class="max-w-2xl text-muted">{render_slot(@inner_block)}</p>
      </div>
      <div :if={@actions != []} class="flex shrink-0 flex-wrap gap-2">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc "Empty state with an icon, a title, a short text and actions."
  attr :id, :string, default: nil
  attr :icon, :string, default: "hero-sparkles"
  attr :title, :string, required: true
  slot :inner_block
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div id={@id} class="empty-state">
      <span class="empty-state-icon"><.icon name={@icon} class="size-6" /></span>
      <p class="font-display text-2xl text-ink">{@title}</p>
      <p :if={@inner_block != []} class="max-w-md text-muted">{render_slot(@inner_block)}</p>
      <div :if={@actions != []} class="flex flex-wrap justify-center gap-2 pt-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc "A [Heroicon](https://heroicons.com) rendered as a CSS mask (`hero-*` classes)."
  attr :name, :string, required: true
  attr :class, :any, default: "size-5"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} aria-hidden="true" />
    """
  end

  ## JS commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 200,
      transition: {"transition-all ease-out duration-200", "opacity-0", "opacity-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 150,
      transition: {"transition-all ease-in duration-150", "opacity-100", "opacity-0"}
    )
  end

  ## Errors

  # Validation messages of the services (Ecto defaults) that have a translation in errors.po;
  # anything else is shown as received.
  @service_errors [
    dgettext_noop("errors", "can't be blank"),
    dgettext_noop("errors", "has already been taken"),
    dgettext_noop("errors", "has invalid format"),
    dgettext_noop("errors", "is invalid"),
    dgettext_noop("errors", "must have the @ sign and no spaces"),
    dgettext_noop("errors", "does not match password"),
    dgettext_noop("errors", "must be 3-24 characters: lowercase letters, digits or underscore"),
    # profil, préférences et avatar (accounts)
    dgettext_noop("errors", "must not contain control characters"),
    dgettext_noop("errors", "has an invalid entry"),
    dgettext_noop("errors", "should have at most 6 item(s)"),
    dgettext_noop("errors", "is not a known time zone"),
    dgettext_noop("errors", "must be a PNG, JPEG or WebP image"),
    dgettext_noop("errors", "must be at most 2 MB"),
    dgettext_noop("errors", "must be between 64 and 2048 pixels wide and high"),
    dgettext_noop("errors", "is not a valid image file"),
    # messagerie : groupes et pièces jointes (social)
    dgettext_noop("errors", "must list 2 to 19 friends"),
    dgettext_noop("errors", "must be a PNG, JPEG or WebP image, or a PDF document"),
    dgettext_noop("errors", "images must be at most 5 MB"),
    dgettext_noop("errors", "PDF documents must be at most 10 MB"),
    dgettext_noop("errors", "images must be between 1 and 8192 pixels wide and high"),
    dgettext_noop("errors", "was rejected by the antivirus"),
    # heures calmes et canaux (notifications)
    dgettext_noop("errors", "must differ from the start"),
    dgettext_noop("errors", "is locked")
  ]

  @doc "Translates a validation error (service messages included, e.g. \"should be at least 12 character(s)\")."
  def translate_error({msg, opts}) do
    case Regex.run(~r/^should be at (least|most) (\d+) character\(s\)$/, msg) do
      [_, "least", n] ->
        dngettext(
          "errors",
          "should be at least %{count} character",
          "should be at least %{count} characters",
          String.to_integer(n)
        )

      [_, "most", n] ->
        dngettext(
          "errors",
          "should be at most %{count} character",
          "should be at most %{count} characters",
          String.to_integer(n)
        )

      nil ->
        if msg in @service_errors or opts != [],
          do: Gettext.dgettext(MysticWeb.Gettext, "errors", msg, opts),
          else: msg
    end
  end
end
