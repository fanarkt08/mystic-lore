defmodule MysticWeb.LessonFormats do
  @moduledoc """
  Rendering of the video, simulation and mini-game lessons; correctness and XP are decided by learning.
  """
  use MysticWeb, :html

  alias MysticWeb.Format

  ## Video

  attr :lesson_id, :string, required: true
  attr :content, :map, required: true
  attr :watched, :integer, required: true
  attr :transcript_open, :boolean, required: true
  attr :transcript_seen, :boolean, required: true
  attr :completed, :boolean, required: true

  attr :captions_on, :boolean,
    default: true,
    doc: "member preference: a caption track shown by default"

  def video_lesson(assigns) do
    assigns =
      assign(assigns,
        captions: assigns.content["captions"] || [],
        default_lang: assigns.captions_on && default_caption(assigns.content["captions"] || []),
        eligible: assigns.watched >= 80 or assigns.transcript_seen
      )

    ~H"""
    <section id="video-lesson" class="space-y-4" aria-label={gettext("Video lesson")}>
      <%!-- ignored by LiveView once mounted: one container per lesson, so that a patch to another video remounts it --%>
      <div
        id={"video-player-#{@lesson_id}"}
        class="lesson-video-frame"
        phx-hook=".VideoProgress"
        phx-update="ignore"
        data-duration={@content["duration_s"]}
      >
        <video
          id="lesson-video"
          class="lesson-video"
          controls
          preload="metadata"
          playsinline
          poster={@content["video"]["poster"]}
        >
          <source src={@content["video"]["src"]} type={@content["video"]["type"]} />
          <track
            :for={c <- @captions}
            kind="captions"
            src={c["src"]}
            srclang={c["lang"]}
            label={c["label"]}
            default={c["lang"] == @default_lang}
          />
          {gettext("Your browser can't play this video: the full transcript is below.")}
        </video>
      </div>
      <p class="text-sm text-muted" id="video-rule">
        {gettext(
          "Captions can be turned on in the player controls (CC or ⋮ menu). To complete the lesson, watch at least 80% of the video or open the transcript."
        )}
      </p>
      <div class="flex flex-wrap items-center gap-3">
        <span id="video-watched" class="lesson-meter">
          <.icon name="hero-play-circle" class="size-5" />
          {gettext("Watched: %{percent}%", percent: @watched)}
        </span>
        <.button
          type="button"
          variant="secondary"
          id="toggle-transcript"
          phx-click="toggle_transcript"
          aria-expanded={to_string(@transcript_open)}
          aria-controls="transcript"
        >
          <.icon name="hero-document-text" />
          {if @transcript_open,
            do: gettext("Hide the transcript"),
            else: gettext("Show the transcript")}
        </.button>
      </div>
      <div id="transcript" class="lesson-transcript story space-y-3" hidden={!@transcript_open}>
        <h2 class="text-2xl">{gettext("Transcript")}</h2>
        <p :for={paragraph <- String.split(@content["transcript"] || "", ~r/\n{2,}/, trim: true)}>
          {paragraph}
        </p>
      </div>
      <.button
        :if={!@completed}
        phx-click="complete"
        id="complete-lesson"
        disabled={!@eligible}
        aria-describedby="video-rule"
        phx-disable-with={gettext("Saving…")}
      >
        <.icon name="hero-check" /> {gettext("Mark complete")}
      </.button>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".VideoProgress">
        // Reports the share of the video actually PLAYED (video.played), in steps of 5%.
        export default {
          mounted() {
            const video = this.el.querySelector("video")
            const fallback = Number(this.el.dataset.duration) || 0
            let sent = 0
            const report = () => {
              const duration = isFinite(video.duration) && video.duration > 0 ? video.duration : fallback
              if (!duration) return
              let played = 0
              for (let i = 0; i < video.played.length; i++) played += video.played.end(i) - video.played.start(i)
              const percent = Math.min(100, Math.floor((played / duration) * 100))
              if (percent >= sent + 5 || (percent >= 80 && sent < 80) || (percent === 100 && sent < 100)) {
                sent = percent
                this.pushEvent("video_progress", {percent})
              }
            }
            video.addEventListener("timeupdate", report)
            video.addEventListener("ended", report)
          }
        }
      </script>
    </section>
    """
  end

  # the interface language first, then English, then the first track
  defp default_caption(captions) do
    langs = Enum.map(captions, & &1["lang"])
    locale = Gettext.get_locale(MysticWeb.Gettext)
    Enum.find([locale, "en"], &(&1 in langs)) || List.first(langs)
  end

  ## Simulation

  attr :content, :map, required: true
  attr :form, :any, required: true
  attr :run, :map, default: nil
  attr :error, :string, default: nil

  def simulation(assigns) do
    assigns =
      assign(assigns, :params, Enum.sort_by(assigns.content["params"] || %{}, &elem(&1, 0)))

    ~H"""
    <section id="simulation" class="space-y-4" aria-labelledby="sim-title">
      <h2 id="sim-title" class="text-2xl">{gettext("Simulation")}</h2>
      <.notice id="sim-goal" kind="info" title={gettext("Goal")}>{@content["goal_text"]}</.notice>
      <.form for={@form} id="sim-form" phx-submit="simulate" novalidate class="card space-y-4">
        <div class="sim-params">
          <.input
            :for={{name, spec} <- @params}
            field={@form[name]}
            type="number"
            inputmode="decimal"
            min={spec["min"]}
            max={spec["max"]}
            step={spec["step"]}
            label={param_label(spec)}
            hint={
              gettext("From %{min} to %{max}, in steps of %{step}.",
                min: spec["min"],
                max: spec["max"],
                step: spec["step"]
              )
            }
          />
        </div>
        <div class="flex flex-wrap gap-3">
          <.button type="submit" name="do" value="run" id="run-sim">
            <.icon name="hero-play" /> {gettext("Run")}
          </.button>
          <.button type="submit" name="do" value="check" variant="secondary" id="check-sim">
            <.icon name="hero-check" /> {gettext("Check")}
          </.button>
        </div>
      </.form>
      <.notice :if={@error} id="sim-error" kind="danger" role="alert">{@error}</.notice>
      <div id="sim-output" aria-live="polite" class="space-y-4">
        <%= if @run do %>
          <p id="sim-description" class="text-ink">{description(@run, @content)}</p>
          <.plot run={@run} content={@content} />
          <dl id="sim-metrics" class="sim-metrics">
            <div :for={{label, value} <- metrics(@run)}>
              <dt>{label}</dt>
              <dd>{value}</dd>
            </div>
          </dl>
          <div
            class="sim-table-scroll"
            role="region"
            aria-labelledby="sim-table-caption"
            tabindex="0"
          >
            <table id="sim-table" class="sim-table">
              <caption id="sim-table-caption">
                {ngettext(
                  "Simulation data (%{count} sampled row)",
                  "Simulation data (%{count} sampled rows)",
                  length(@run["frames"])
                )}
              </caption>
              <thead>
                <tr>
                  <th :for={col <- @run["columns"]} scope="col">
                    {column_label(col, @run["model"])}
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @run["frames"]}>
                  <td :for={value <- row}>{number(value)}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <p class="text-xs text-muted" id="sim-engine">
            {gettext("Computed by the server (%{engine} engine).",
              engine: engine_label(@run["engine"])
            )}
          </p>
        <% end %>
      </div>
    </section>
    """
  end

  defp param_label(%{"label" => label, "unit" => unit}) when unit not in [nil, ""],
    do: "#{label} (#{unit})"

  defp param_label(spec), do: spec["label"]

  defp column_label(col, model) do
    name = column_name(col, model)

    case unit_label(col["unit"]) do
      nil -> name
      unit -> "#{name} (#{unit})"
    end
  end

  # The server's fixed columns, named in the member's language (a species keeps its formula).
  defp column_name(%{"key" => "pass"}, "reaction"), do: gettext("Pass")

  defp column_name(%{"key" => "atoms_" <> element}, "reaction"),
    do: gettext("%{element} atoms", element: element)

  defp column_name(%{"key" => "t"}, "orbit"), do: gettext("Time")
  defp column_name(%{"key" => "r"}, "orbit"), do: gettext("Distance")
  defp column_name(col, _model), do: col["label"]

  defp unit_label(unit) when unit in [nil, ""], do: nil
  defp unit_label("AU"), do: gettext("AU")
  defp unit_label("yr"), do: gettext("yr")
  defp unit_label(unit), do: unit

  defp engine_label("native"), do: gettext("native")
  defp engine_label("elixir"), do: "Elixir"
  defp engine_label(engine), do: engine

  defp metrics(%{"model" => "orbit", "metrics" => m}) do
    [
      {gettext("Eccentricity (0 = circle)"), number(m["eccentricity"])},
      {gettext("Closest distance"), gettext("%{distance} AU", distance: number(m["r_min"]))},
      {gettext("Farthest distance"), gettext("%{distance} AU", distance: number(m["r_max"]))},
      {gettext("Full orbits"), m["revolutions"]},
      {gettext("Period"),
       if(m["period"], do: gettext("%{period} yr", period: number(m["period"])), else: "—")},
      {gettext("Outcome"),
       cond do
         m["collided"] -> gettext("fell into the star")
         m["escaped"] -> gettext("escaped")
         m["bound"] -> gettext("bound orbit")
         true -> gettext("not bound: it will escape")
       end}
    ]
  end

  defp metrics(%{"model" => "reaction", "metrics" => m}) do
    [
      {gettext("Atoms on the left"), atoms(m["atoms_left"])},
      {gettext("Atoms on the right"), atoms(m["atoms_right"])},
      {gettext("Atoms conserved"), if(m["balanced"], do: gettext("yes"), else: gettext("no"))},
      {gettext("Smallest whole numbers"),
       if(m["lowest_terms"], do: gettext("yes"), else: gettext("no"))},
      {gettext("Overall yield"), gettext("%{percent}%", percent: round(m["yield"] * 100))},
      {gettext("Limiting reactant"), m["limiting"]}
    ]
  end

  defp metrics(_run), do: []

  @doc false
  # The server's English sentence stays the reference: the same sentence is composed here in the member's
  # language, from the run's figures and the values sent (kept in the run by `MysticWeb.LearnLive`).
  def description(
        %{"model" => "reaction", "metrics" => %{} = m, "values" => %{} = values},
        %{"species" => [_ | _] = species} = content
      )
      when is_number(:erlang.map_get("formed", m)) and
             is_number(:erlang.map_get("theoretical", m)) and
             is_number(:erlang.map_get("yield", m)) do
    side = fn which ->
      species
      |> Enum.filter(&(&1["side"] == which))
      |> Enum.map_join(" + ", fn s ->
        case coefficient(values[s["key"]]) do
          1 -> s["formula"]
          n -> "#{n} #{s["formula"]}"
        end
      end)
    end

    product = Enum.find(species, %{}, &(&1["side"] == "product"))

    conservation =
      if m["balanced"],
        do: gettext("Every atom is conserved."),
        else: gettext("Atoms are not conserved: the totals drift from pass to pass.")

    Enum.join(
      [
        gettext("%{equation}. Atoms on the left: %{left}; on the right: %{right}.",
          equation: side.("reactant") <> " → " <> side.("product"),
          left: atoms(m["atoms_left"]),
          right: atoms(m["atoms_right"])
        ),
        conservation,
        gettext(
          "After %{steps} passes at %{yield}% per pass, %{formed} mol of %{product} formed (%{percent}% of the %{theoretical} mol possible; limiting reactant: %{limiting}).",
          steps: content["steps"],
          yield: content["yield_pct"],
          formed: Format.decimal(m["formed"], 2),
          product: product["formula"],
          percent: round(m["yield"] * 100),
          theoretical: Format.decimal(m["theoretical"], 2),
          limiting: m["limiting"]
        )
      ],
      " "
    )
  end

  def description(
        %{"model" => "orbit", "metrics" => %{} = m, "frames" => [[t | _] | _] = frames},
        _content
      )
      when is_number(t) and is_number(:erlang.map_get("r_min", m)) and
             is_number(:erlang.map_get("r_max", m)) and
             is_number(:erlang.map_get("eccentricity", m)) do
    t = frames |> List.last() |> hd() |> Format.decimal(2)

    cond do
      m["collided"] ->
        gettext(
          "The planet fell into its star after %{t} years. Closest distance %{distance} AU.",
          t: t,
          distance: Format.decimal(m["r_min"], 3)
        )

      m["escaped"] ->
        gettext(
          "The planet escaped beyond 100 AU after %{t} years: the star's gravity could not hold it.",
          t: t
        )

      true ->
        turns =
          case m["revolutions"] do
            n when is_integer(n) and n > 0 ->
              ngettext(
                "In %{t} years the planet completed %{count} full orbit",
                "In %{t} years the planet completed %{count} full orbits",
                n,
                t: t
              )

            _ ->
              gettext("In %{t} years the planet did not complete a full orbit", t: t)
          end

        period =
          if is_number(m["period"]),
            do:
              " " <>
                gettext("(one turn every %{period} years)",
                  period: Format.decimal(m["period"], 2)
                ),
            else: ""

        turns <>
          period <>
          ". " <>
          gettext(
            "Its distance from the star stayed between %{closest} and %{farthest} AU: eccentricity %{eccentricity} (0 is a perfect circle).",
            closest: Format.decimal(m["r_min"], 3),
            farthest: Format.decimal(m["r_max"], 3),
            eccentricity: Format.decimal(m["eccentricity"], 3)
          )
    end
  end

  def description(run, _content), do: run["description"]

  defp coefficient(value) when is_number(value), do: trunc(value)
  defp coefficient(_value), do: 1

  @doc """
  The message of a simulation check in the member's language, from the server's `feedback_code` and
  `feedback_params`; `nil` for an unknown code (the server's English `feedback` is then shown).
  """
  def sim_feedback("reaction_balanced", _params),
    do: gettext("Every atom is conserved: the equation is balanced.")

  def sim_feedback("reaction_common_factor", _params),
    do:
      gettext(
        "Every atom is conserved, but the coefficients share a common factor: use the smallest whole numbers."
      )

  def sim_feedback("reaction_unbalanced", %{
        "element" => element,
        "left" => left,
        "right" => right
      })
      when is_integer(left) and is_integer(right) do
    ngettext(
      "Not balanced yet: %{element} has %{count} atom on the left and %{right} on the right. Atoms are never created or destroyed.",
      "Not balanced yet: %{element} has %{count} atoms on the left and %{right} on the right. Atoms are never created or destroyed.",
      left,
      element: element,
      right: right
    )
  end

  def sim_feedback("orbit_collided", _params),
    do: gettext("The planet fell into its star: it was too slow for its orbit.")

  def sim_feedback("orbit_escaped", _params),
    do: gettext("The planet escaped: it was too fast for the star's gravity to hold it.")

  def sim_feedback("orbit_few_turns", _params),
    do: gettext("The planet did not complete enough full orbits in the simulated time.")

  def sim_feedback("orbit_elongated", %{"eccentricity" => e}) when is_binary(e),
    do:
      gettext(
        "The orbit closes, but it is too elongated (eccentricity %{eccentricity}): adjust the speed to make it rounder.",
        eccentricity: localized(e)
      )

  def sim_feedback("orbit_stable", %{"eccentricity" => e, "period" => p})
      when is_binary(e) and is_binary(p),
      do:
        gettext(
          "A stable, nearly circular orbit: eccentricity %{eccentricity}, one turn every %{period} years.",
          eccentricity: localized(e),
          period: localized(p)
        )

  def sim_feedback(_code, _params), do: nil

  # A decimal written by the server ("0.004"), in the member's language.
  defp localized(text),
    do:
      if(Gettext.get_locale(MysticWeb.Gettext) == "fr",
        do: String.replace(text, ".", ","),
        else: text
      )

  defp atoms(map) when is_map(map),
    do: map |> Enum.sort() |> Enum.map_join(", ", fn {el, n} -> "#{el} #{n}" end)

  defp atoms(_), do: "—"

  @doc false
  def number(value) when is_integer(value), do: Integer.to_string(value)

  def number(value) when is_float(value) do
    rounded = Float.round(value, 4)

    text =
      if rounded == trunc(rounded),
        do: Integer.to_string(trunc(rounded)),
        else: to_string(rounded)

    localized(text)
  end

  def number(value), do: to_string(value)

  attr :run, :map, required: true
  attr :content, :map, required: true

  # Decorative plot (the table and the description carry the same data for assistive technologies).
  defp plot(%{run: %{"plot" => %{"type" => "path"}} = run} = assigns) do
    points = Enum.map(run["frames"], fn [_t, x, y | _] -> {x, -y} end)
    {sx, sy} = scaler([{0.0, 0.0} | points])
    assigns = assign(assigns, path: polyline(points, sx, sy), star: {sx.(0.0), sy.(0.0)})

    ~H"""
    <svg id="sim-plot" class="sim-plot" viewBox="0 0 100 100" aria-hidden="true" focusable="false">
      <polyline points={@path} class="sim-line" />
      <circle cx={elem(@star, 0)} cy={elem(@star, 1)} r="2.6" class="sim-star" />
    </svg>
    """
  end

  defp plot(%{run: %{"plot" => %{"type" => "lines", "y" => keys}} = run} = assigns) do
    columns = Enum.map(run["columns"], & &1["key"])

    series =
      for {key, i} <- Enum.with_index(keys) do
        index = Enum.find_index(columns, &(&1 == key))
        label = Enum.at(run["columns"], index)["label"]
        {label, i, Enum.map(run["frames"], &{hd(&1) * 1.0, Enum.at(&1, index) * 1.0})}
      end

    {sx, sy} = scaler(Enum.flat_map(series, &elem(&1, 2)))

    assigns =
      assign(assigns,
        series: for({label, i, points} <- series, do: {label, i, polyline(points, sx, sy)})
      )

    ~H"""
    <figure class="space-y-2" aria-hidden="true">
      <svg
        id="sim-plot"
        class="sim-plot sim-plot-wide"
        viewBox="0 0 100 100"
        preserveAspectRatio="none"
        focusable="false"
      >
        <polyline :for={{_label, i, path} <- @series} points={path} class={"sim-line sim-line-#{i}"} />
      </svg>
      <figcaption class="sim-legend">
        <span :for={{label, i, _} <- @series} class={"sim-key sim-key-#{i}"}>{label}</span>
      </figcaption>
    </figure>
    """
  end

  defp plot(assigns), do: ~H""

  # maps data coordinates to a 6..94 box, keeping proportions for paths
  defp scaler(points) do
    {xs, ys} = Enum.unzip(points)
    {x0, x1} = Enum.min_max(xs)
    {y0, y1} = Enum.min_max(ys)
    span = fn a, b -> if b - a == 0, do: 1.0, else: b - a end
    sx = fn x -> Float.round(6 + (x - x0) / span.(x0, x1) * 88, 2) end
    sy = fn y -> Float.round(94 - (y - y0) / span.(y0, y1) * 88, 2) end
    {sx, sy}
  end

  defp polyline(points, sx, sy),
    do: Enum.map_join(points, " ", fn {x, y} -> "#{sx.(x)},#{sy.(y)}" end)

  ## Mini-games

  attr :content, :map, required: true
  attr :order, :list, required: true
  attr :moves, :integer, required: true
  attr :path, :list, required: true
  attr :announce, :string, required: true

  def minigame(assigns) do
    ~H"""
    <section id="minigame" class="space-y-4" aria-labelledby="game-title" phx-hook=".GameFocus">
      <h2 id="game-title" class="text-2xl">{gettext("Mini-game")}</h2>
      <p id="game-prompt" class="text-xl text-ink">{@content["prompt"]}</p>
      <%= case @content["game"] do %>
        <% "sequence" -> %>
          <.sequence content={@content} order={@order} moves={@moves} />
        <% "constellation" -> %>
          <.constellation content={@content} path={@path} />
        <% _ -> %>
      <% end %>
      <p id="game-announce" class="sr-only" aria-live="polite">{@announce}</p>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".GameFocus">
        // keeps the keyboard focus on the moved item (its button is re-rendered at its new place)
        export default {
          mounted() {
            this.handleEvent("game:focus", ({id}) => document.getElementById(id)?.focus())
          }
        }
      </script>
    </section>
    """
  end

  # width (map units) of the pastille under a star's place(s) in the path, e.g. « 2 » or « 2·7 »
  defp place_width(places), do: 1.4 + 1.5 * String.length(Enum.join(places, "·"))

  # width (map units) of the text of a star's name (3-unit font), generous so the pastille always covers it
  defp name_width(name), do: 2.1 * String.length(to_string(name))

  attr :content, :map, required: true
  attr :order, :list, required: true
  attr :moves, :integer, required: true

  defp sequence(assigns) do
    items = Map.new(assigns.content["items"] || [], &{&1["id"], &1})

    assigns =
      assign(assigns, items: Enum.map(assigns.order, &items[&1]), count: length(assigns.order))

    ~H"""
    <p class="text-sm text-muted" id="sequence-help">
      {gettext(
        "Reorder the list with the Move up and Move down buttons (Tab to reach them, Enter to press), then check the order."
      )}
    </p>
    <ol id="sequence-list" class="sequence-list" aria-describedby="sequence-help">
      <li :for={{item, i} <- Enum.with_index(@items)} id={"item-#{item["id"]}"} class="sequence-item">
        <span class="sequence-position">{i + 1}</span>
        <span class="min-w-0 flex-1">{item["label"]}</span>
        <span class="flex gap-1">
          <.button
            type="button"
            variant="ghost"
            class="btn-icon"
            id={"item-#{item["id"]}-up"}
            phx-click="move"
            phx-value-id={item["id"]}
            phx-value-dir="up"
            disabled={i == 0}
            aria-label={gettext("Move “%{label}” up", label: item["label"])}
          >
            <.icon name="hero-arrow-up" />
          </.button>
          <.button
            type="button"
            variant="ghost"
            class="btn-icon"
            id={"item-#{item["id"]}-down"}
            phx-click="move"
            phx-value-id={item["id"]}
            phx-value-dir="down"
            disabled={i == @count - 1}
            aria-label={gettext("Move “%{label}” down", label: item["label"])}
          >
            <.icon name="hero-arrow-down" />
          </.button>
        </span>
      </li>
    </ol>
    <div class="flex flex-wrap items-center gap-3">
      <.button id="check-game" phx-click="check_game"><.icon name="hero-check" /> {gettext(
        "Check the order"
      )}</.button>
      <.button id="reset-game" variant="ghost" phx-click="reset_game">{gettext("Start again")}</.button>
      <span id="game-moves" class="text-sm text-muted">
        {ngettext("%{count} move", "%{count} moves", @moves)}
      </span>
    </div>
    """
  end

  attr :content, :map, required: true
  attr :path, :list, required: true

  defp constellation(assigns) do
    stars = assigns.content["stars"] || []
    by_id = Map.new(stars, &{&1["id"], &1})
    points = Enum.map(assigns.path, &by_id[&1])

    assigns =
      assign(assigns,
        stars: stars,
        names: Enum.map(points, & &1["name"]),
        segments: Enum.chunk_every(points, 2, 1, :discard),
        positions: fn id ->
          for {p, i} <- Enum.with_index(assigns.path, 1), p == id, do: i
        end
      )

    ~H"""
    <svg id="star-map" class="star-map" viewBox="0 0 100 100" aria-hidden="true" focusable="false">
      <line
        :for={[a, b] <- @segments}
        x1={a["x"]}
        y1={a["y"]}
        x2={b["x"]}
        y2={b["y"]}
        class="star-link"
      />
      <g :for={star <- @stars}>
        <circle
          cx={star["x"]}
          cy={star["y"]}
          r={if @positions.(star["id"]) != [], do: "2.6", else: "1.8"}
          class={["star-dot", @positions.(star["id"]) != [] && "star-dot-picked"]}
        />
        <rect
          x={
            if star["x"] > 60,
              do: star["x"] - 4 - name_width(star["name"]),
              else: star["x"] + 2
          }
          y={star["y"] - 6.2}
          width={name_width(star["name"]) + 2}
          height="5"
          rx="1"
          class="star-name-bg"
        />
        <text
          x={if star["x"] > 60, do: star["x"] - 3, else: star["x"] + 3}
          y={star["y"] - 3}
          text-anchor={if star["x"] > 60, do: "end", else: "start"}
          class="star-name"
        >
          {star["name"]}
        </text>
        <rect
          :if={@positions.(star["id"]) != []}
          x={star["x"] - place_width(@positions.(star["id"])) / 2}
          y={star["y"] + 3.5}
          width={place_width(@positions.(star["id"]))}
          height="3.6"
          rx="1"
          class="star-place-bg"
        />
        <text
          :if={@positions.(star["id"]) != []}
          x={star["x"]}
          y={star["y"] + 6}
          text-anchor="middle"
          class="star-place"
        >
          {Enum.join(@positions.(star["id"]), "·")}
        </text>
      </g>
    </svg>
    <p class="text-sm text-muted" id="stars-help">
      {gettext(
        "Select the stars in order with the buttons below (Tab, then Enter). Each selected star shows its place in your path; select a star again to come back to it."
      )}
    </p>
    <ul id="star-list" class="star-list" aria-describedby="stars-help">
      <li :for={star <- @stars}>
        <button
          type="button"
          id={"star-#{star["id"]}"}
          class="star-button"
          phx-click="pick_star"
          phx-value-id={star["id"]}
        >
          <span class="font-medium text-ink">{star["name"]}</span>
          <span class="text-xs text-muted">{where(star)}</span>
          <span :if={@positions.(star["id"]) != []} class="star-order">
            {gettext("in your path: %{places}", places: Enum.join(@positions.(star["id"]), ", "))}
          </span>
        </button>
      </li>
    </ul>
    <p id="star-path" class="text-ink">
      <%= if @names == [] do %>
        {gettext("No star selected yet.")}
      <% else %>
        {gettext("Your path: %{path}", path: Enum.join(@names, " → "))}
      <% end %>
    </p>
    <div class="flex flex-wrap gap-3">
      <.button id="check-game" phx-click="check_game"><.icon name="hero-check" /> {gettext(
        "Check the path"
      )}</.button>
      <.button id="undo-star" variant="secondary" phx-click="undo_star" disabled={@path == []}>
        {gettext("Undo the last star")}
      </.button>
      <.button id="reset-game" variant="ghost" phx-click="reset_game">{gettext("Clear")}</.button>
    </div>
    """
  end

  # text alternative of a star's place on the map (x to the right, y downwards)
  defp where(%{"x" => x, "y" => y}) do
    row =
      if y < 34,
        do: gettext("top"),
        else: if(y < 67, do: gettext("middle"), else: gettext("bottom"))

    col =
      if x < 34,
        do: gettext("left"),
        else: if(x < 67, do: gettext("center"), else: gettext("right"))

    gettext("%{row} %{col} of the map", row: row, col: col)
  end
end
