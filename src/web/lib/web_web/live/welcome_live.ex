defmodule MysticWeb.WelcomeLive do
  @moduledoc """
  Welcome tour in five steps, proposed after the first login and saved through the accounts APIs.
  """
  use MysticWeb, :live_view

  import MysticWeb.SettingsComponents,
    only: [choice_group: 1, check: 1, field_errors: 1, zone_options: 2]

  import MysticWeb.ProfileComponents, only: [interest_categories: 1, interest_label: 1]
  alias MysticWeb.{Auth, Preferences, ProfileComponents}

  @steps ~w(language interests goal accessibility adventures)

  def steps, do: @steps

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       assign(socket,
         page_title: gettext("Welcome to MysticLore"),
         errors: %{},
         status: nil,
         recommendations: nil
       )}

  @impl true
  def handle_params(params, _uri, socket) do
    step = if params["step"] in @steps, do: params["step"], else: "language"

    socket =
      assign(socket,
        step: step,
        index: Enum.find_index(@steps, &(&1 == step)),
        errors: %{}
      )

    {:noreply, if(step == "adventures", do: load_recommendations(socket), else: socket)}
  end

  defp load_recommendations(socket) do
    categories = interest_categories(socket.assigns.current_user["interests"] || [])

    case Api.get(socket, :learning, "/api/me/dashboard",
           params: [categories: Enum.join(categories, ",")]
         ) do
      {:ok, %{"recommendations" => list}} when is_list(list) ->
        assign(socket, recommendations: Enum.take(list, 3))

      _ ->
        assign(socket, recommendations: :unavailable)
    end
  end

  defp next_step(step), do: Enum.at(@steps, Enum.find_index(@steps, &(&1 == step)) + 1)

  defp previous_step(step) do
    case Enum.find_index(@steps, &(&1 == step)) do
      0 -> nil
      i -> Enum.at(@steps, i - 1)
    end
  end

  defp step_path(step), do: ~p"/welcome?#{[step: step]}"

  ## Saves (the user returned by accounts becomes the current one, the preferences are applied at once)

  @impl true
  def handle_event("save_language", %{"welcome" => params}, socket) do
    before = Gettext.get_locale(MysticWeb.Gettext)
    attrs = Map.take(params, ~w(language time_zone))

    case save(socket, "/api/me/preferences", attrs, [:language, :time_zone]) do
      {:ok, socket} ->
        message = gettext("Language and time zone saved.")
        locale = locale(socket)

        if locale == before do
          {:noreply, advance(socket, message)}
        else
          # every text of the page and `<html lang>` change: full reload, in the new language
          Gettext.put_locale(MysticWeb.Gettext, locale)

          {:noreply,
           socket
           |> put_flash(:info, gettext("Language and time zone saved."))
           |> redirect(to: step_path(next_step(socket.assigns.step)))}
        end

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("save_interests", params, socket) do
    interests =
      params
      |> get_in(["welcome", "interests"])
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))

    case save(socket, "/api/me", %{interests: interests}, [:interests]) do
      {:ok, socket} -> {:noreply, advance(socket, gettext("Interests saved."))}
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("save_goal", %{"welcome" => %{"daily_xp_goal" => goal}}, socket) do
    case save(socket, "/api/me/preferences", %{daily_xp_goal: goal}, [:daily_xp_goal]) do
      {:ok, socket} -> {:noreply, advance(socket, gettext("Daily goal saved."))}
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("save_goal", _params, socket),
    do: {:noreply, assign(socket, errors: %{daily_xp_goal: [gettext("Choose a goal first.")]})}

  def handle_event("save_accessibility", %{"welcome" => params}, socket) do
    attrs =
      params
      |> Map.take(~w(reduce_motion high_contrast underline_links captions text_size))
      |> Map.new(fn
        {"text_size", value} -> {"text_size", value}
        {key, value} -> {key, value == "true"}
      end)

    fields = [:reduce_motion, :high_contrast, :underline_links, :captions, :text_size]

    case save(socket, "/api/me/preferences", attrs, fields) do
      {:ok, socket} -> {:noreply, advance(socket, gettext("Accessibility settings saved."))}
      {:error, socket} -> {:noreply, socket}
    end
  end

  def handle_event("skip_step", _params, socket) do
    case next_step(socket.assigns.step) do
      nil -> {:noreply, socket}
      step -> {:noreply, socket |> assign(status: nil) |> push_patch(to: step_path(step))}
    end
  end

  def handle_event("skip_tour", _params, socket) do
    case onboarding(socket, "skipped") do
      {:ok, socket} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Welcome tour skipped. You can restart it from your settings.")
         )
         |> push_navigate(to: ~p"/dashboard")}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("finish", params, socket) do
    to = Auth.return_path(params["to"]) || ~p"/dashboard"

    case onboarding(socket, "completed") do
      {:ok, socket} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("You're all set. Enjoy your first chapter!"))
         |> push_navigate(to: to)}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  defp onboarding(socket, status) do
    case Api.put(socket, :accounts, "/api/me/onboarding", json: %{status: status}) do
      {:ok, %{"user" => %{"id" => _} = user}} -> {:ok, assign(socket, current_user: user)}
      error -> {:error, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  defp save(socket, path, attrs, fields) do
    case Api.patch(socket, :accounts, path, json: attrs) do
      {:ok, %{"user" => %{"id" => _} = user}} ->
        {:ok, socket |> assign(current_user: user, errors: %{}) |> Preferences.refresh()}

      {:error, {:http, 422, _}} = error ->
        errors =
          error
          |> Api.form_errors(fields)
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

        {:error, assign(socket, errors: errors, status: nil)}

      error ->
        {:error, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  defp advance(socket, message) do
    socket
    |> assign(status: message)
    |> push_patch(to: step_path(next_step(socket.assigns.step)))
  end

  # Language of the page after a save: the member's choice, else this browser's (`auto`).
  defp locale(socket) do
    case Preferences.of(socket.assigns.current_user)["language"] do
      lang when lang in ~w(en fr) -> lang
      _auto -> socket.assigns[:browser_locale] || "en"
    end
  end

  defp step_title("language"), do: gettext("Language and time zone")
  defp step_title("interests"), do: gettext("What do you like to learn?")
  defp step_title("goal"), do: gettext("Your daily goal")
  defp step_title("accessibility"), do: gettext("Reading and display comfort")
  defp step_title("adventures"), do: gettext("Adventures for you")

  ## Rendering

  @impl true
  def render(assigns) do
    assigns = assign(assigns, prefs: Preferences.of(assigns.current_user), steps: @steps)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
    >
      <div class="welcome mx-auto max-w-3xl space-y-6">
        <header class="space-y-3">
          <p class="eyebrow">{gettext("Welcome, %{name}", name: @current_user["display_name"])}</p>
          <h1 class="text-4xl md:text-5xl">{gettext("Let's set up your academy")}</h1>
          <p class="text-muted">
            {gettext(
              "Five short steps, each saved at once. You can skip any of them and change everything later in your settings."
            )}
          </p>
        </header>

        <nav aria-label={gettext("Welcome tour steps")}>
          <ol id="welcome-steps" class="welcome-steps">
            <li
              :for={{step, i} <- Enum.with_index(@steps)}
              class={["welcome-step", i < @index && "is-done", step == @step && "is-current"]}
              aria-current={step == @step && "step"}
            >
              <span class="welcome-step-number" aria-hidden="true">{i + 1}</span>
              <span class="welcome-step-label">{step_title(step)}</span>
            </li>
          </ol>
        </nav>

        <p id="welcome-progress" class="text-sm text-muted">
          {gettext("Step %{n} of %{total}", n: @index + 1, total: length(@steps))}
        </p>
        <p id="welcome-status" class="save-status" role="status" aria-live="polite">
          <span :if={@status} class="inline-flex items-center gap-2 text-success">
            <.icon name="hero-check-circle" class="size-5" /> {@status}
          </span>
        </p>

        <section
          id={"welcome-step-#{@step}"}
          class="card space-y-5"
          aria-labelledby="welcome-step-title"
        >
          <h2 id="welcome-step-title" class="text-3xl">{step_title(@step)}</h2>
          <.step_body
            step={@step}
            prefs={@prefs}
            user={@current_user}
            errors={@errors}
            time_zone={@time_zone}
            browser_time_zone={@browser_time_zone}
            recommendations={@recommendations}
          />
        </section>

        <div class="welcome-footer">
          <.link
            :if={previous_step(@step)}
            patch={step_path(previous_step(@step))}
            class="btn btn-ghost"
            id="welcome-back"
          >
            ← {gettext("Back")}
          </.link>
          <button
            :if={next_step(@step)}
            type="button"
            class="btn btn-ghost"
            id="welcome-skip-step"
            phx-click="skip_step"
          >
            {gettext("Skip this step")}
          </button>
          <button
            type="button"
            class="btn btn-ghost"
            id="welcome-skip-tour"
            phx-click="skip_tour"
          >
            {gettext("Skip the welcome tour")}
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :step, :string, required: true
  attr :prefs, :map, required: true
  attr :user, :map, required: true
  attr :errors, :map, required: true
  attr :time_zone, :string, default: nil
  attr :browser_time_zone, :string, default: nil
  attr :recommendations, :any, default: nil

  defp step_body(%{step: "language"} = assigns) do
    ~H"""
    <.form
      for={%{}}
      as={:welcome}
      id="welcome-language-form"
      phx-submit="save_language"
      class="space-y-5"
    >
      <.choice_group
        id="welcome-language"
        name="welcome[language]"
        legend={gettext("Language")}
        value={@prefs["language"]}
        options={[
          {"auto", gettext("Automatic"), gettext("Follows the language of this browser.")},
          {"en", "English"},
          {"fr", "Français"}
        ]}
        errors={@errors[:language] || []}
      />
      <.input
        type="select"
        id="welcome-time-zone"
        name="welcome[time_zone]"
        label={gettext("Time zone")}
        value={@prefs["time_zone"]}
        options={zone_options(@prefs["time_zone"], @browser_time_zone)}
        errors={Enum.map(@errors[:time_zone] || [], &translate_error/1)}
        hint={
          gettext("Dates and times are shown in this zone. Now: %{zone}.",
            zone: zone_label(@time_zone)
          )
        }
      />
      <.button type="submit" id="welcome-save" phx-disable-with={gettext("Saving…")}>
        {gettext("Save and continue")}
      </.button>
    </.form>
    """
  end

  defp step_body(%{step: "interests"} = assigns) do
    ~H"""
    <.form
      for={%{}}
      as={:welcome}
      id="welcome-interests-form"
      phx-submit="save_interests"
      class="space-y-5"
    >
      <fieldset class="space-y-3" aria-describedby="welcome-interests-hint">
        <legend class="label">{gettext("Interests")}</legend>
        <p id="welcome-interests-hint" class="field-hint">
          {gettext("Up to 6. They order the adventures we recommend to you.")}
        </p>
        <input type="hidden" name="welcome[interests][]" value="" />
        <div class="choice-grid">
          <.check
            :for={key <- ProfileComponents.interests()}
            id={"welcome-interest-#{key}"}
            name="welcome[interests][]"
            value={key}
            unchecked={nil}
            checked={key in (@user["interests"] || [])}
            label={interest_label(key)}
          />
        </div>
        <.field_errors id="welcome-interests-error" errors={@errors[:interests] || []} />
      </fieldset>
      <.button type="submit" id="welcome-save" phx-disable-with={gettext("Saving…")}>
        {gettext("Save and continue")}
      </.button>
    </.form>
    """
  end

  defp step_body(%{step: "goal"} = assigns) do
    ~H"""
    <.form for={%{}} as={:welcome} id="welcome-goal-form" phx-submit="save_goal" class="space-y-5">
      <.choice_group
        id="welcome-goal"
        name="welcome[daily_xp_goal]"
        legend={gettext("Daily XP goal")}
        hint={gettext("Your dashboard shows your progress towards it each day.")}
        value={@prefs["daily_xp_goal"]}
        options={[
          {10, gettext("10 XP"), gettext("A quick lesson")},
          {20, gettext("20 XP"), gettext("A steady pace")},
          {50, gettext("50 XP"), gettext("An ambitious day")},
          {100, gettext("100 XP"), gettext("A true quest")}
        ]}
        errors={@errors[:daily_xp_goal] || []}
      />
      <.button type="submit" id="welcome-save" phx-disable-with={gettext("Saving…")}>
        {gettext("Save and continue")}
      </.button>
    </.form>
    """
  end

  defp step_body(%{step: "accessibility"} = assigns) do
    ~H"""
    <.form
      for={%{}}
      as={:welcome}
      id="welcome-accessibility-form"
      phx-submit="save_accessibility"
      class="space-y-5"
    >
      <p class="text-sm text-muted">
        {gettext("Applied at once on every page, on every device you use.")}
      </p>
      <div class="grid gap-2">
        <.check
          id="welcome-reduce-motion"
          name="welcome[reduce_motion]"
          checked={@prefs["reduce_motion"]}
          label={gettext("Reduce motion")}
          hint={gettext("No animations or transitions, even if your device doesn't ask for it.")}
        />
        <.check
          id="welcome-high-contrast"
          name="welcome[high_contrast]"
          checked={@prefs["high_contrast"]}
          label={gettext("High contrast")}
        />
        <.check
          id="welcome-underline-links"
          name="welcome[underline_links]"
          checked={@prefs["underline_links"]}
          label={gettext("Underline links")}
        />
        <.check
          id="welcome-captions"
          name="welcome[captions]"
          checked={@prefs["captions"]}
          label={gettext("Captions on by default in video lessons")}
        />
      </div>
      <.choice_group
        id="welcome-text-size"
        name="welcome[text_size]"
        legend={gettext("Text size")}
        value={@prefs["text_size"]}
        options={for size <- [100, 112, 125, 150], do: {size, "#{size} %"}}
        errors={@errors[:text_size] || []}
        class="choice-row"
      />
      <.button type="submit" id="welcome-save" phx-disable-with={gettext("Saving…")}>
        {gettext("Save and continue")}
      </.button>
    </.form>
    """
  end

  defp step_body(%{step: "adventures"} = assigns) do
    ~H"""
    <p class="text-muted">
      {gettext(
        "Chosen by the academy from your interests (free adventures first). Pick one to start, or finish the tour."
      )}
    </p>
    <%= case @recommendations do %>
      <% :unavailable -> %>
        <.unavailable id="welcome-recommendations-unavailable">
          {gettext("Recommendations can't be loaded right now.")}
        </.unavailable>
      <% [] -> %>
        <p id="welcome-no-recommendation" class="text-muted">
          {gettext("You have started every adventure we could recommend: browse the catalogue.")}
        </p>
      <% adventures when is_list(adventures) -> %>
        <ul id="welcome-recommendations" class="grid gap-4 md:grid-cols-3">
          <li :for={a <- adventures} id={"welcome-adventure-#{a["slug"]}"} class="card space-y-3">
            <.art cover={a["cover"]} class="aspect-[16/9] rounded-control" />
            <div class="flex flex-wrap gap-2">
              <.tag>{category_label(a["category"])}</.tag>
              <.access_tag premium={a["premium"] == true} />
            </div>
            <h3 class="text-xl">{a["title"]}</h3>
            <p class="text-sm text-muted">{a["summary"]}</p>
            <button
              type="button"
              class="btn btn-secondary w-full"
              id={"welcome-start-#{a["slug"]}"}
              phx-click="finish"
              phx-value-to={~p"/adventures/#{a["slug"]}"}
            >
              {gettext("Start here")}
            </button>
          </li>
        </ul>
      <% _ -> %>
    <% end %>
    <button type="button" class="btn btn-primary" id="welcome-finish" phx-click="finish">
      <.icon name="hero-check" /> {gettext("Finish and go to my dashboard")}
    </button>
    """
  end
end
