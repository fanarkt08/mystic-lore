defmodule MysticWeb.LearnLive do
  @moduledoc """
  Lesson player for every format; correctness and XP are decided by learning.
  """
  use MysticWeb, :live_view
  import MysticWeb.LessonFormats
  import MysticWeb.LessonContent, only: [lesson_text: 1, quiz_fields: 1]

  @impl true
  def mount(%{"slug" => slug}, _session, socket),
    do:
      {:ok,
       assign(socket,
         slug: slug,
         page_title: gettext("Lesson"),
         premium_adventure: false,
         access: :none,
         access_live: false
       )}

  @impl true
  def handle_params(%{"lesson_id" => id}, _uri, socket),
    do: {:noreply, socket |> assign(lesson_id: id) |> load(id)}

  defp load(socket, id) do
    socket =
      assign(socket,
        result: nil,
        draft_status: nil,
        notes_status: nil,
        watched: 0,
        transcript_open: false,
        transcript_seen: false,
        sim_run: nil,
        sim_error: nil,
        announce: ""
      )

    case Api.get(socket, :learning, "/api/lessons/:id", path_params: [id: id]) do
      {:ok, %{"lesson" => %{"id" => _} = lesson} = data} ->
        progress = data["progress"] || %{}
        content = lesson["content"] || %{}

        socket
        |> assign(
          state: :ok,
          lesson: lesson,
          content: content,
          data: data,
          slug: get_in(data, ["adventure", "slug"]) || socket.assigns.slug,
          page_title: lesson["title"],
          completed: progress["status"] == "completed",
          code_form: to_form(%{"code" => progress["draft"] || content["starter"] || ""}),
          notes_form: to_form(%{"notes" => progress["notes"] || ""})
        )
        |> reset_game()
        |> assign(sim_form: sim_form(content, sim_defaults(content), []))
        |> load_outline()

      {:error, {:http, 404, _}} ->
        raise MysticWeb.NotFoundError

      {:error, {:http, 402, _}} ->
        socket |> assign(state: :premium, access_live: false) |> load_access()

      error ->
        assign(socket, state: {:error, Api.error_message(error)})
    end
  end

  # An ended Premium access also asks the browser to delete the premium lessons it keeps offline.
  defp load_access(socket) do
    case Api.get(socket, :billing, "/api/me/billing") do
      {:ok, %{"entitlements" => %{} = entitlements}} ->
        access = access_end(entitlements)
        socket = assign(socket, access: access)

        case access do
          {:ended, at} -> MysticWeb.Offline.push_purge(socket, at)
          _ -> socket
        end

      _ ->
        assign(socket, access: :none)
    end
  end

  defp load_outline(socket) do
    case Api.get(socket, :learning, "/api/adventures/:slug",
           path_params: [slug: socket.assigns.slug]
         ) do
      {:ok, %{"chapters" => chapters} = adventure} when is_list(chapters) ->
        assign(socket, outline: chapters, premium_adventure: adventure["premium"] == true)

      _ ->
        assign(socket, outline: :unavailable)
    end
  end

  @impl true
  def handle_event("complete", _params, socket) do
    # a video reports what the browser measured (learning can't verify the viewing itself)
    body =
      if socket.assigns.lesson["kind"] == "video",
        do: %{
          watched_percent: socket.assigns.watched,
          transcript_opened: socket.assigns.transcript_seen
        },
        else: %{}

    Api.post(socket, :learning, "/api/lessons/:id/complete",
      path_params: [id: lesson_id(socket)],
      json: body
    )
    |> show_result(socket)
  end

  def handle_event("check", %{"answer" => answer}, socket) when answer not in [nil, ""],
    do: submit(socket, answer)

  def handle_event("check", _params, socket),
    do: {:noreply, assign(socket, result: %{error: gettext("Choose an answer first.")})}

  def handle_event("run", %{"code" => code}, socket), do: submit(socket, code)

  def handle_event("draft", %{"code" => code}, socket) do
    status =
      if String.length(code) > 2000 do
        {:error, gettext("Your spell is longer than 2,000 characters: the draft can't be saved.")}
      else
        Api.put(socket, :learning, "/api/lessons/:id/draft",
          path_params: [id: lesson_id(socket)],
          json: %{draft: code}
        )
        |> save_result()
      end

    {:noreply, assign(socket, draft_status: status, code_form: to_form(%{"code" => code}))}
  end

  ## Video

  def handle_event("video_progress", %{"percent" => percent}, socket) when is_integer(percent),
    do: {:noreply, assign(socket, watched: max(socket.assigns.watched, min(percent, 100)))}

  def handle_event("toggle_transcript", _params, socket) do
    open = !socket.assigns.transcript_open

    {:noreply,
     assign(socket,
       transcript_open: open,
       transcript_seen: socket.assigns.transcript_seen or open
     )}
  end

  ## Simulation

  def handle_event("simulate", %{"params" => raw} = params, socket) do
    values = Map.new(raw, fn {name, value} -> {name, parse_number(value)} end)
    socket = assign(socket, sim_form: sim_form(socket.assigns.content, raw, []), sim_error: nil)

    if params["do"] == "check" do
      submit(socket, Jason.encode!(values))
    else
      case Api.post(socket, :learning, "/api/lessons/:id/simulate",
             path_params: [id: lesson_id(socket)],
             json: %{params: values}
           ) do
        {:ok, %{"frames" => _} = run} ->
          # the values sent stay with the run: the description is composed from them in the member's language
          {:noreply, assign(socket, sim_run: Map.put(run, "values", values))}

        error ->
          {:noreply, sim_failed(socket, raw, error)}
      end
    end
  end

  ## Mini-games

  def handle_event("move", %{"id" => id, "dir" => dir}, socket) when dir in ["up", "down"] do
    order = socket.assigns.game_order
    index = Enum.find_index(order, &(&1 == id))
    target = if dir == "up", do: index && index - 1, else: index && index + 1

    if index && target in 0..(length(order) - 1)//1 do
      order =
        order |> List.replace_at(index, Enum.at(order, target)) |> List.replace_at(target, id)

      label = Enum.find(socket.assigns.content["items"], &(&1["id"] == id))["label"]
      # at the top (bottom) the same button is disabled: the other one gets the focus
      button =
        cond do
          target == 0 -> "down"
          target == length(order) - 1 -> "up"
          true -> dir
        end

      {:noreply,
       socket
       |> assign(
         game_order: order,
         game_moves: socket.assigns.game_moves ++ [%{"id" => id, "dir" => dir}],
         announce:
           gettext("“%{label}” moved to position %{position} of %{count}.",
             label: label,
             position: target + 1,
             count: length(order)
           )
       )
       |> push_event("game:focus", %{id: "item-#{id}-#{button}"})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pick_star", %{"id" => id}, socket) do
    star = Enum.find(socket.assigns.content["stars"] || [], &(&1["id"] == id))

    if star && length(socket.assigns.game_path) < 40 do
      path = socket.assigns.game_path ++ [id]

      {:noreply,
       assign(socket,
         game_path: path,
         announce:
           gettext("%{name} added: star %{n} of your path.", name: star["name"], n: length(path))
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("undo_star", _params, socket) do
    {:noreply,
     assign(socket,
       game_path: Enum.drop(socket.assigns.game_path, -1),
       announce: gettext("Last star removed.")
     )}
  end

  def handle_event("reset_game", _params, socket),
    do:
      {:noreply,
       socket |> reset_game() |> assign(announce: gettext("Back to the start."), result: nil)}

  def handle_event("check_game", _params, socket) do
    moves =
      if socket.assigns.content["game"] == "constellation",
        do: socket.assigns.game_path,
        else: socket.assigns.game_moves

    submit(socket, Jason.encode!(%{moves: moves}))
  end

  def handle_event("save_notes", %{"notes" => notes}, socket) do
    status =
      Api.put(socket, :learning, "/api/lessons/:id/notes",
        path_params: [id: lesson_id(socket)],
        json: %{notes: notes}
      )
      |> save_result()

    {:noreply, assign(socket, notes_status: status, notes_form: to_form(%{"notes" => notes}))}
  end

  defp lesson_id(socket), do: socket.assigns.lesson["id"]

  defp save_result({:ok, _}), do: :saved
  defp save_result(error), do: {:error, Api.error_message(error)}

  defp submit(socket, answer) do
    Api.post(socket, :learning, "/api/lessons/:id/submit",
      path_params: [id: lesson_id(socket)],
      json: %{answer: answer}
    )
    |> show_result(socket)
  end

  defp show_result({:ok, %{} = body}, socket) do
    result = %{
      correct: body["correct"] != false,
      xp: body["xp"],
      feedback: sim_feedback(body["feedback_code"], body["feedback_params"]) || body["feedback"],
      trace: body["trace"],
      score: body["score"]
    }

    socket = assign(socket, result: result)

    {:noreply,
     if(result.correct, do: socket |> assign(completed: true) |> load_outline(), else: socket)}
  end

  defp show_result({:error, {:http, 402, _}}, socket),
    do: {:noreply, socket |> assign(state: :premium, access_live: true) |> load_access()}

  defp show_result({:error, {:http, 422, %{"errors" => %{}}}} = error, socket)
       when is_map_key(socket.assigns.lesson, "kind") do
    if socket.assigns.lesson["kind"] == "simulation",
      do: {:noreply, sim_failed(socket, socket.assigns.sim_form.params, error)},
      else: {:noreply, assign(socket, result: %{error: Api.error_message(error)})}
  end

  defp show_result(error, socket),
    do: {:noreply, assign(socket, result: %{error: Api.error_message(error)})}

  # The member's plan changed while the lesson is open (billing → `"user:<id>"`): an ended Premium access closes a
  # premium lesson at once (announced), a renewed one opens it again.
  @impl true
  def handle_info({:entitlements_changed, _user_id, plan}, socket) do
    paid? = plan in ~w(premium vip)

    cond do
      socket.assigns[:state] == :ok and socket.assigns.premium_adventure and not paid? ->
        {:noreply, socket |> assign(state: :premium, access_live: true) |> load_access()}

      socket.assigns[:state] == :premium and paid? ->
        {:noreply, load(socket, socket.assigns.lesson_id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp reset_game(%{assigns: %{content: content}} = socket),
    do:
      assign(socket,
        game_order: Enum.map(content["items"] || [], & &1["id"]),
        game_moves: [],
        game_path: []
      )

  defp sim_defaults(content),
    do:
      Map.new(content["params"] || %{}, fn {name, spec} -> {name, to_string(spec["default"])} end)

  defp sim_form(content, raw, errors) do
    values = Map.new(content["params"] || %{}, fn {name, _} -> {name, raw[name]} end)
    to_form(values, as: :params, errors: errors)
  end

  # learning answered 422: errors per parameter (`params.<name>`) next to their field
  defp sim_failed(socket, raw, {:error, {:http, 422, %{"errors" => errors}}})
       when is_map(errors) do
    names = Map.keys(socket.assigns.content["params"] || %{})

    field_errors =
      for {"params." <> name, messages} <- errors,
          name in names,
          message <- List.wrap(messages),
          do: {name, {message, []}}

    assign(socket,
      sim_form: sim_form(socket.assigns.content, raw, field_errors),
      sim_error:
        gettext("Some values are outside what this simulation accepts: see the fields above."),
      result: nil
    )
  end

  defp sim_failed(socket, _raw, error), do: assign(socket, sim_error: Api.error_message(error))

  defp parse_number(value) when is_binary(value) do
    value = String.trim(value)

    case Float.parse(value) do
      {number, ""} -> if String.contains?(value, [".", "e", "E"]), do: number, else: trunc(number)
      _ -> value
    end
  end

  defp parse_number(value), do: value

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:adventures}
    >
      <%= case @state do %>
        <% :premium -> %>
          <%= case @access do %>
            <% {:ended, at} -> %>
              <.access_state
                id="lesson-premium-ended"
                icon="hero-clock"
                tone="reward"
                live={@access_live}
                title={
                  if at,
                    do: gettext("Your Premium access ended on %{date}", date: date(at)),
                    else: gettext("Your Premium access has ended")
                }
              >
                {gettext(
                  "This lesson belongs to a Premium adventure. Your progress is kept: renew your membership to continue where you stopped."
                )}
                <:actions>
                  <.button navigate={~p"/membership"} variant="reward" id="lesson-renew">
                    <.icon name="hero-sparkles" /> {gettext("Renew my membership")}
                  </.button>
                  <.button navigate={~p"/adventures/#{@slug}"} variant="ghost">
                    {gettext("Back to the adventure")}
                  </.button>
                </:actions>
              </.access_state>
            <% _ -> %>
              <.access_state
                id="lesson-premium"
                icon="hero-sparkles"
                tone="reward"
                live={@access_live}
                title={gettext("This lesson is part of a Premium adventure")}
              >
                {gettext("Upgrade your membership to continue this adventure.")}
                <:actions>
                  <.button navigate={~p"/membership"} variant="reward" id="lesson-upgrade">
                    <.icon name="hero-sparkles" /> {gettext("See membership")}
                  </.button>
                  <.button navigate={~p"/adventures/#{@slug}"} variant="ghost">
                    {gettext("Back to the adventure")}
                  </.button>
                </:actions>
              </.access_state>
          <% end %>
        <% {:error, message} -> %>
          <.notice id="lesson-unavailable" kind="warning" title={gettext("Temporarily unavailable")}>
            {message}
            <:actions>
              <%!-- même « Try again » que les autres états indisponibles : la page est montée de nouveau --%>
              <button
                type="button"
                class="btn btn-secondary"
                id="lesson-unavailable-retry"
                phx-click="ml:retry"
              >
                <.icon name="hero-arrow-path" /> {gettext("Try again")}
              </button>
              <.button navigate={~p"/adventures/#{@slug}"} variant="ghost">
                {gettext("Back to the adventure")}
              </.button>
            </:actions>
          </.notice>
        <% :ok -> %>
          <div class="grid gap-8 lg:grid-cols-[16rem_minmax(0,1fr)] xl:grid-cols-[18rem_minmax(0,1fr)]">
            <aside class="hidden lg:block">
              <div class="sticky top-8 card p-4">
                <.outline outline={@outline} slug={@slug} current={@lesson["id"]} />
              </div>
            </aside>

            <article class="min-w-0 space-y-8" id={"lesson-#{@lesson["id"]}"}>
              <header class="space-y-4">
                <.link navigate={~p"/adventures/#{@slug}"} class="link text-sm">
                  ← {get_in(@data, ["adventure", "title"]) || gettext("Back to the adventure")}
                </.link>
                <div class="flex flex-wrap gap-2">
                  <.tag icon={kind_icon(@lesson["kind"])}>{kind_label(@lesson["kind"])}</.tag>
                  <.tag kind="premium" icon="hero-bolt">
                    {gettext("%{xp} XP", xp: @lesson["xp_reward"])}
                  </.tag>
                  <.tag :if={@completed} kind="success" icon="hero-check" id="lesson-completed">
                    {gettext("Completed")}
                  </.tag>
                </div>
                <h1 class="text-4xl md:text-5xl">{@lesson["title"]}</h1>
              </header>

              <.lesson_text lesson={@lesson} />

              <%= case @lesson["kind"] do %>
                <% "story" -> %>
                  <.button
                    phx-click="complete"
                    id="complete-lesson"
                    phx-disable-with={gettext("Saving…")}
                  >
                    <.icon name="hero-check" /> {gettext("Mark complete")}
                  </.button>
                <% "exercise" -> %>
                  <.quiz content={@content} />
                <% "coding" -> %>
                  <.coding content={@content} form={@code_form} draft_status={@draft_status} />
                <% "video" -> %>
                  <.video_lesson
                    lesson_id={@lesson["id"]}
                    content={@content}
                    watched={@watched}
                    transcript_open={@transcript_open}
                    transcript_seen={@transcript_seen}
                    completed={@completed}
                    captions_on={@preferences["captions"]}
                  />
                <% "simulation" -> %>
                  <.simulation content={@content} form={@sim_form} run={@sim_run} error={@sim_error} />
                <% "minigame" -> %>
                  <.minigame
                    content={@content}
                    order={@game_order}
                    moves={length(@game_moves)}
                    path={@game_path}
                    announce={@announce}
                  />
                <% _ -> %>
              <% end %>

              <div id="lesson-result" aria-live="polite">
                <.result :if={@result} result={@result} lesson={@lesson} content={@content} />
              </div>

              <MysticWeb.OfflineComponents.lesson_card
                :if={get_in(@data, ["offline", "available"]) == true}
                lesson={@lesson}
                slug={@slug}
                offline={@data["offline"]}
              />

              <section class="card space-y-3" aria-labelledby="notes-title">
                <h2 id="notes-title" class="text-2xl">{gettext("My notes")}</h2>
                <.form for={@notes_form} id="notes-form" phx-submit="save_notes" class="space-y-3">
                  <.input
                    field={@notes_form[:notes]}
                    type="textarea"
                    rows="4"
                    maxlength="4000"
                    label={gettext("Private notes for this lesson (only you can see them)")}
                  />
                  <div class="flex flex-wrap items-center gap-3">
                    <.button type="submit" variant="secondary" id="save-notes">{gettext("Save notes")}</.button>
                    <p id="notes-status" class="text-sm" aria-live="polite">
                      <.saved_status status={@notes_status} saved={gettext("Notes saved.")} />
                    </p>
                  </div>
                </.form>
              </section>

              <nav
                class="flex flex-wrap justify-between gap-3"
                aria-label={gettext("Lesson navigation")}
              >
                <.button
                  :if={@data["prev_id"]}
                  patch={~p"/learn/#{@slug}/#{@data["prev_id"]}"}
                  variant="ghost"
                  id="prev-lesson"
                >
                  <.icon name="hero-arrow-left" /> {gettext("Previous lesson")}
                </.button>
                <span :if={!@data["prev_id"]}></span>
                <.button
                  :if={@data["next_id"]}
                  patch={~p"/learn/#{@slug}/#{@data["next_id"]}"}
                  id="next-lesson"
                >
                  {gettext("Next lesson")} <.icon name="hero-arrow-right" />
                </.button>
                <.button
                  :if={!@data["next_id"]}
                  navigate={~p"/adventures/#{@slug}"}
                  variant="secondary"
                  id="end-adventure"
                >
                  {gettext("Back to the adventure")}
                </.button>
              </nav>

              <details class="faq lg:hidden">
                <summary>{gettext("All chapters")}</summary>
                <.outline outline={@outline} slug={@slug} current={@lesson["id"]} />
              </details>
            </article>
          </div>
      <% end %>
    </Layouts.app>
    """
  end

  attr :outline, :any, required: true
  attr :slug, :string, required: true
  attr :current, :string, required: true

  defp outline(assigns) do
    ~H"""
    <nav aria-label={gettext("Chapters")} class="space-y-5">
      <p :if={@outline == :unavailable} class="text-sm text-muted">
        {gettext("Chapters can't be loaded right now.")}
      </p>
      <div :for={chapter <- if(is_list(@outline), do: @outline, else: [])} class="space-y-2">
        <p class="eyebrow">{gettext("Chapter %{n}", n: chapter["position"])}</p>
        <p class="font-display text-xl text-ink">{chapter["title"]}</p>
        <ol class="space-y-1">
          <li :for={lesson <- chapter["lessons"] || []}>
            <.link
              patch={~p"/learn/#{@slug}/#{lesson["id"]}"}
              class="outline-link"
              aria-current={lesson["id"] == @current && "page"}
            >
              <.icon
                name={
                  if lesson["completed"],
                    do: "hero-check-circle-solid",
                    else: kind_icon(lesson["kind"])
                }
                class={[
                  "size-4 shrink-0",
                  if(lesson["completed"], do: "text-success", else: "text-muted")
                ]}
              />
              <span class="min-w-0 flex-1">{lesson["title"]}</span>
              <span :if={lesson["completed"]} class="sr-only">{gettext("Completed")}</span>
            </.link>
          </li>
        </ol>
      </div>
    </nav>
    """
  end

  attr :content, :map, required: true

  defp quiz(assigns) do
    ~H"""
    <.form for={%{}} id="quiz-form" phx-submit="check" class="card space-y-4">
      <.quiz_fields content={@content} />
      <.button type="submit" id="check-answer" phx-disable-with={gettext("Checking…")}>
        {gettext("Check")}
      </.button>
    </.form>
    """
  end

  attr :content, :map, required: true
  attr :form, :any, required: true
  attr :draft_status, :any, default: nil

  defp coding(assigns) do
    ~H"""
    <section class="space-y-4" aria-label={gettext("Coding exercise")}>
      <.notice :if={@content["language_note"]} kind="info">{@content["language_note"]}</.notice>
      <details :if={(@content["hints"] || []) != []} class="faq">
        <summary>{gettext("Hints")}</summary>
        <ol class="list-decimal space-y-1 pl-5 text-muted">
          <li :for={hint <- @content["hints"]}>{hint}</li>
        </ol>
      </details>
      <.form for={@form} id="code-form" phx-change="draft" phx-submit="run" class="card space-y-3">
        <.input
          field={@form[:code]}
          type="textarea"
          rows="8"
          maxlength="2000"
          spellcheck="false"
          autocapitalize="off"
          class="code-editor"
          phx-debounce="800"
          label={gettext("Your spell")}
          hint={gettext("Indent with 4 spaces. Your draft is saved automatically while you type.")}
        />
        <div class="flex flex-wrap items-center gap-3">
          <.button type="submit" id="run-code" phx-disable-with={gettext("Running…")}>
            <.icon name="hero-play" /> {gettext("Run & check")}
          </.button>
          <p id="draft-status" class="text-sm" aria-live="polite">
            <.saved_status status={@draft_status} saved={gettext("Draft saved.")} />
          </p>
        </div>
      </.form>
    </section>
    """
  end

  attr :result, :map, required: true
  attr :lesson, :map, required: true
  attr :content, :map, required: true

  defp result(%{result: %{error: _}} = assigns) do
    ~H"""
    <.notice kind="danger" role="alert">{@result.error}</.notice>
    """
  end

  defp result(assigns) do
    ~H"""
    <.notice
      id="result"
      kind={if @result.correct, do: "success", else: "danger"}
      title={if @result.correct, do: gettext("Well done!"), else: gettext("Not quite — try again")}
    >
      <p :if={@result.feedback}>{@result.feedback}</p>
      <p :if={is_integer(@result[:score])} id="game-score" class="font-medium text-ink">
        {gettext("Score: %{score}/100", score: @result.score)}
      </p>
      <.grove :if={is_list(@result.trace)} trace={@result.trace} plants={@content["plants"]} />
      <p :if={@result.xp == "awarded"} id="xp-awarded" class="xp-gain">
        <.icon name="hero-bolt" /> {gettext("+%{xp} XP", xp: @lesson["xp_reward"])}
      </p>
      <p :if={@result.xp == "duplicate"} id="xp-duplicate" class="text-sm text-muted">
        {gettext("Already completed — XP granted once.")}
      </p>
    </.notice>
    """
  end

  attr :trace, :list, required: true
  attr :plants, :any, default: nil

  defp grove(assigns) do
    assigns =
      assign(
        assigns,
        :count,
        if(is_integer(assigns.plants) and assigns.plants > 0, do: assigns.plants, else: 3)
      )

    ~H"""
    <div class="space-y-3 pt-2">
      <p id="grove-trace" class="font-mono text-sm text-ink">
        {if @trace == [],
          do: gettext("No plant was watered."),
          else: gettext("watered %{plants}", plants: Enum.join(@trace, ", "))}
      </p>
      <ul class="grove" aria-label={gettext("The grove after your spell")}>
        <li :for={i <- 0..(@count - 1)} class={["sapling", i in @trace && "sapling-watered"]}>
          <.icon name={if i in @trace, do: "hero-sparkles", else: "hero-minus-circle"} class="size-6" />
          <span class="text-sm">{gettext("Plant %{n}", n: i)}</span>
          <span class="text-xs">{if i in @trace, do: gettext("watered"), else: gettext("dry")}</span>
        </li>
      </ul>
    </div>
    """
  end

  attr :status, :any, required: true
  attr :saved, :string, required: true

  defp saved_status(assigns) do
    ~H"""
    <%= case @status do %>
      <% :saved -> %>
        <span class="inline-flex items-center gap-1 text-success">
          <.icon name="hero-check" class="size-4" /> {@saved}
        </span>
      <% {:error, message} -> %>
        <span class="text-danger">{message}</span>
      <% _ -> %>
    <% end %>
    """
  end
end
