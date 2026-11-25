defmodule MlStudio.Publishing.Checks do
  @moduledoc "Automatic publication checks, run on a snapshot with the limits of the learning import."

  @keys ~w(structure objectives titles quizzes grovescript image_alt no_html lengths links videos simulations minigames)

  def run(%{"brief" => brief, "modules" => modules} = snapshot) do
    lessons =
      for {m, i} <- Enum.with_index(modules, 1),
          {l, j} <- Enum.with_index(m["lessons"], 1),
          do: {l, %{"module" => i, "lesson" => j, "title" => l["title"]}}

    texts = texts(brief, modules, lessons, snapshot["images"] || [])
    media = snapshot["media"] || []

    issues = %{
      "structure" => structure(modules),
      "objectives" => objectives(brief["objectives"]),
      "titles" => titles(brief, modules, lessons),
      "quizzes" =>
        for(
          {%{"kind" => "exercise"} = l, at} <- lessons,
          code <- quiz(l["content"]),
          do: issue(code, at)
        ),
      "grovescript" =>
        for(
          {%{"kind" => "coding"} = l, at} <- lessons,
          code <- grove(l["content"]),
          do: issue(code, at)
        ),
      "image_alt" =>
        for(
          img <- snapshot["images"] || [],
          not between?(img["alt"], 1, 300),
          do: issue("image_alt", %{"image" => img["id"]})
        ),
      "no_html" =>
        for(
          {field, text, at} <- texts,
          html?(text),
          do: issue("html", Map.put(at, "field", field))
        ),
      "lengths" => lengths(brief, lessons),
      "videos" =>
        for(
          {%{"kind" => "video"} = l, at} <- lessons,
          code <- video(l["content"], media),
          do: issue(code, at)
        ),
      "simulations" =>
        for(
          {%{"kind" => "simulation"} = l, at} <- lessons,
          code <- simulation(l["content"]),
          do: issue(code, at)
        ),
      "minigames" =>
        for(
          {%{"kind" => "minigame"} = l, at} <- lessons,
          code <- minigame(l["content"]),
          do: issue(code, at)
        ),
      "links" =>
        for(
          {field, text, at} <- texts,
          bad_link?(text),
          do: issue("link", Map.put(at, "field", field))
        )
    }

    for key <- @keys, do: %{"key" => key, "ok" => issues[key] == [], "issues" => issues[key]}
  end

  def ok?(checks), do: Enum.all?(checks, & &1["ok"])

  defp structure([]), do: [issue("no_modules")]

  defp structure(modules) do
    per_module =
      for {m, i} <- Enum.with_index(modules, 1),
          code <-
            (case length(m["lessons"]) do
               0 -> ["empty_module"]
               n when n > 30 -> ["too_many_lessons"]
               _ -> []
             end),
          do: issue(code, %{"module" => i, "title" => m["title"]})

    if(length(modules) > 20, do: [issue("too_many_modules")], else: []) ++ per_module
  end

  defp objectives(list) do
    cond do
      list == [] ->
        [issue("no_objectives")]

      length(list) > 10 ->
        [issue("too_many_objectives")]

      true ->
        for {o, i} <- Enum.with_index(list, 1),
            not between?(o, 1, 200),
            do: issue("objective", %{"index" => i})
    end
  end

  defp titles(brief, modules, lessons) do
    if(between?(brief["title"], 3, 120), do: [], else: [issue("project_title")]) ++
      for(
        {m, i} <- Enum.with_index(modules, 1),
        not between?(m["title"], 1, 120),
        do: issue("module_title", %{"module" => i})
      ) ++
      for {l, at} <- lessons, not between?(l["title"], 1, 120), do: issue("lesson_title", at)
  end

  defp quiz(c) do
    choices = Enum.map(c["choices"] || [], &String.trim/1)

    [
      {not between?(c["question"], 1, 500), "quiz_question"},
      {length(choices) not in 2..6 or Enum.any?(choices, &(not between?(&1, 1, 200))) or
         length(Enum.uniq(choices)) != length(choices), "quiz_choices"},
      {not (is_integer(c["answer"]) and c["answer"] in 0..(length(choices) - 1)//1),
       "quiz_answer"},
      {not between?(c["explanation"], 1, 1000), "quiz_explanation"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp grove(c) do
    hints = c["hints"] || []
    starter = String.trim(c["starter"] || "")

    [
      {not (is_integer(c["plants"]) and c["plants"] in 2..10), "grove_plants"},
      {starter == "" or byte_size(starter) > 600, "grove_starter"},
      {length(hints) not in 1..5 or Enum.any?(hints, &(not between?(&1, 1, 300))), "grove_hints"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp video(c, media) do
    ids = fn kind -> for m <- media, m["kind"] == kind, into: MapSet.new(), do: m["id"] end
    captions = c["captions"] || []

    [
      {not MapSet.member?(ids.("video"), c["video_id"]), "video_file"},
      {captions == [] or
         Enum.any?(captions, &(not MapSet.member?(ids.("captions"), &1["media_id"]))),
       "video_captions"},
      {not between?(c["transcript"], 1, 50_000), "video_transcript"},
      {not (is_integer(c["duration_s"]) and c["duration_s"] in 1..7200), "video_duration"}
    ]
    |> codes()
  end

  # limits of the learning engines (learning MlLearning.Sim.Orbit / Reaction), in the author's units
  @orbit_hard %{"velocity" => {0, 20}, "star_mass" => {0.1, 10}}

  defp simulation(%{"model" => "orbit"} = c) do
    [
      {not between?(c["goal_text"], 1, 500), "sim_goal"},
      {not (is_integer(c["steps"]) and c["steps"] in 10..20_000), "sim_steps"},
      {not (range?(c["velocity"], @orbit_hard["velocity"]) and
              range?(c["star_mass"], @orbit_hard["star_mass"]) and within?(c["distance"], 0.1, 10) and
              within?(c["dt"], 0.0001, 0.02)), "sim_params"},
      {not (within?(c["max_eccentricity"], 0.001, 0.5) and
              (is_integer(c["min_revolutions"]) and c["min_revolutions"] in 1..10)),
       "sim_objective"}
    ]
    |> codes()
  end

  defp simulation(%{"model" => "reaction"} = c) do
    species = c["species"] || []
    sides = Enum.map(species, & &1["side"])
    formulas = Enum.map(species, & &1["formula"])
    atoms = Enum.map(formulas, &formula/1)

    [
      {not between?(c["goal_text"], 1, 500), "sim_goal"},
      {not (is_integer(c["steps"]) and c["steps"] in 1..100), "sim_steps"},
      {length(species) not in 2..6 or "reactant" not in sides or "product" not in sides or
         Enum.any?(atoms, &(&1 == :error)) or length(Enum.uniq(formulas)) != length(formulas) or
         length(
           atoms
           |> Enum.reject(&(&1 == :error))
           |> Enum.flat_map(&Map.keys/1)
           |> Enum.uniq()
         ) > 6 or
         Enum.any?(species, &(not within?(&1["initial"], 0, 1000))), "sim_species"},
      {not (is_integer(c["max_coefficient"]) and c["max_coefficient"] in 1..12 and
              is_integer(c["yield_pct"]) and c["yield_pct"] in 1..100), "sim_params"}
    ]
    |> codes()
  end

  defp simulation(_c), do: ["sim_model"]

  # min < max inside the hard bounds, step > 0 dividing the range (≤ 10000 values), default on the grid
  defp range?(%{"min" => min, "max" => max, "step" => step, "default" => d}, {lo, hi}) do
    with [min, max, step, d, lo, hi] <- fixed([min, max, step, d, lo, hi]) do
      min >= lo and max <= hi and min < max and step > 0 and rem(max - min, step) == 0 and
        div(max - min, step) <= 10_000 and d >= min and d <= max and rem(d - min, step) == 0
    else
      _ -> false
    end
  end

  defp range?(_range, _hard), do: false

  defp within?(x, lo, hi), do: is_number(x) and x >= lo and x <= hi and fixed([x]) != :error

  defp fixed(values) do
    if Enum.all?(values, &(is_number(&1) and abs(&1 * 1.0e6 - round(&1 * 1.0e6)) < 1.0e-3)),
      do: Enum.map(values, &round(&1 * 1.0e6)),
      else: :error
  end

  # simple formulas only (no parentheses): `H2O` → %{"H" => 2, "O" => 1}
  defp formula(f) when is_binary(f) and f != "" do
    parts = Regex.scan(~r/([A-Z][a-z]?)(\d*)/, f)

    if Enum.map_join(parts, &hd/1) == f and
         Enum.all?(parts, fn [_, _, n] -> n == "" or String.to_integer(n) in 1..20 end),
       do: Map.new(parts, fn [_, el, n] -> {el, n} end),
       else: :error
  end

  defp formula(_f), do: :error

  defp minigame(%{"game" => "sequence"} = c) do
    items = Enum.map(c["items"] || [], &String.trim/1)

    [
      {not between?(c["prompt"], 1, 500), "game_prompt"},
      {length(items) not in 3..10 or Enum.any?(items, &(not between?(&1, 1, 200))) or
         length(Enum.uniq(items)) != length(items), "game_items"}
    ]
    |> codes()
  end

  defp minigame(%{"game" => "constellation"} = c) do
    stars = c["stars"] || []
    names = Enum.map(stars, &String.trim(&1["name"] || ""))
    path = Enum.map(c["path"] || [], &String.trim/1)

    [
      {not between?(c["prompt"], 1, 500), "game_prompt"},
      {length(stars) not in 3..12 or Enum.any?(names, &(not between?(&1, 1, 60))) or
         length(Enum.uniq(names)) != length(names) or
         Enum.any?(stars, &(not (&1["x"] in 0..100 and &1["y"] in 0..100))), "game_stars"},
      {length(path) not in 2..20 or Enum.any?(path, &(&1 not in names)) or
         Enum.any?(Enum.chunk_every(path, 2, 1, :discard), fn [a, b] -> a == b end), "game_path"}
    ]
    |> codes()
  end

  defp minigame(_c), do: ["game_type"]

  defp codes(checks), do: checks |> Enum.filter(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

  defp lengths(brief, lessons) do
    brief_issues = [
      {not between?(brief["summary"], 1, 300), "summary"},
      {String.length(brief["description"] || "") > 5000, "description"},
      {not (is_integer(brief["duration_minutes"]) and brief["duration_minutes"] in 5..600),
       "duration"}
    ]

    for({true, code} <- brief_issues, do: issue(code)) ++
      for {l, at} <- lessons,
          {true, code} <- [
            {not between?(l["body"], 1, 20_000), "body"},
            {not (is_integer(l["xp_reward"]) and l["xp_reward"] in 1..100), "xp"}
          ],
          do: issue(code, at)
  end

  # Every text a learner will read: {field, text, location}.
  defp texts(brief, modules, lessons, images) do
    brief_texts =
      [
        {"title", brief["title"]},
        {"summary", brief["summary"]},
        {"description", brief["description"]},
        {"audience", brief["audience"]}
      ] ++
        Enum.map(brief["objectives"], &{"objectives", &1}) ++
        Enum.map(brief["prerequisites"], &{"prerequisites", &1})

    for({field, text} <- brief_texts, do: {field, text, %{}}) ++
      for(
        {m, i} <- Enum.with_index(modules, 1),
        do: {"module_title", m["title"], %{"module" => i}}
      ) ++
      for({l, at} <- lessons, {field, text} <- lesson_texts(l), do: {field, text, at}) ++
      for(img <- images, do: {"alt", img["alt"], %{"image" => img["id"]}})
  end

  defp lesson_texts(%{"content" => c} = l) do
    [{"title", l["title"]}, {"body", l["body"]}] ++
      case l["kind"] do
        "exercise" ->
          [{"question", c["question"]}, {"explanation", c["explanation"]}] ++
            Enum.map(c["choices"] || [], &{"choices", &1})

        "coding" ->
          [{"starter", c["starter"]}] ++ Enum.map(c["hints"] || [], &{"hints", &1})

        "video" ->
          [{"transcript", c["transcript"]}] ++
            Enum.map(c["captions"] || [], &{"captions", &1["label"]})

        "simulation" ->
          [{"goal_text", c["goal_text"]}] ++
            Enum.map(c["species"] || [], &{"species", &1["formula"]})

        "minigame" ->
          [{"prompt", c["prompt"]}] ++
            Enum.map(c["items"] || [], &{"items", &1}) ++
            Enum.map(c["stars"] || [], &{"stars", &1["name"]}) ++
            Enum.map(c["path"] || [], &{"path", &1})

        _ ->
          []
      end
  end

  defp between?(text, min, max) when is_binary(text),
    do: String.length(String.trim(text)) in min..max

  defp between?(_text, _min, _max), do: false

  # A tag, a comment or a processing instruction: `<b`, `</p`, `<!--`, `<?`.
  defp html?(text) when is_binary(text), do: Regex.match?(~r/<\s*[a-zA-Z!\/?]/, text)
  defp html?(_text), do: false

  defp bad_link?(text) when is_binary(text) do
    Regex.match?(~r/\b(javascript|vbscript|data|file):/i, text) or
      Enum.any?(Regex.scan(~r/\b([a-z][a-z0-9+.\-]*):\/\//i, text), fn [_, scheme] ->
        String.downcase(scheme) not in ["http", "https"]
      end)
  end

  defp bad_link?(_text), do: false

  defp issue(code, at \\ %{}),
    do:
      Map.merge(
        %{
          "code" => code,
          "module" => nil,
          "lesson" => nil,
          "title" => nil,
          "field" => nil,
          "image" => nil
        },
        at
      )
end
