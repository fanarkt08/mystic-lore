defmodule MlLearning.Sim do
  @moduledoc """
  Leçons `simulation` : configuration, paramètres de l'apprenant, présentation et objectif.
  Le moteur ne reçoit que des entiers bornés, et le critère de réussite n'est jamais exposé.
  """
  alias MlLearning.Sim.Engine

  @scale 1.0e6
  @models ~w(orbit reaction)

  @orbit_inputs %{
    "velocity" => {"Launch speed", "AU/yr", 6.3},
    "star_mass" => {"Star mass", "M☉", 1.0},
    "planet_mass" => {"Planet mass", "M☉", 0.001},
    "distance" => {"Starting distance", "AU", 1.0},
    "dt" => {"Time step", "yr", 0.002}
  }

  def models, do: @models

  ## Configuration (seeds, import)

  @doc "Valide et normalise `{content, solution}` : `{:ok, content, solution}` ou `{:error, message}`."
  def validate(content, solution) when is_map(content) do
    solution = if is_map(solution), do: solution, else: %{}

    with {:ok, goal} <- text(content["goal_text"], 1, 500, "goal_text"),
         {:ok, model_content, criterion} <- model(content["model"], content, solution) do
      {:ok, Map.merge(model_content, %{"model" => content["model"], "goal_text" => goal}),
       criterion}
    end
  end

  def validate(_content, _solution), do: {:error, "content must be an object"}

  defp model("orbit", c, s) do
    hard = MlLearning.Sim.Orbit.bounds()

    with {:ok, steps} <- int(c["steps"], 10, 20_000, "steps"),
         {:ok, params} <-
           params(c["params"], fn name ->
             with {label, unit, _} <- @orbit_inputs[name],
                  {lo, hi} <- hard[name],
                  do: {:ok, label, unit, lo, hi}
           end),
         {:ok, fixed} <- fixed(c["fixed"] || %{}, params, hard),
         {:ok, max_e} <- number(s["max_eccentricity"], 0.001, 0.5, "max_eccentricity"),
         {:ok, min_rev} <- int(s["min_revolutions"] || 1, 1, 10, "min_revolutions") do
      {:ok, %{"params" => params, "fixed" => fixed, "steps" => steps},
       %{"max_eccentricity" => max_e, "min_revolutions" => min_rev}}
    end
  end

  defp model("reaction", c, s) do
    with {:ok, steps} <- int(c["steps"], 1, 100, "steps"),
         {:ok, yield_pct} <- int(c["yield_pct"], 1, 100, "yield_pct"),
         {:ok, species} <- species(c["species"]),
         {:ok, params} <-
           params(c["params"], fn key ->
             case Enum.find(species, &(&1["key"] == key)) do
               nil -> :error
               sp -> {:ok, "Coefficient of #{sp["formula"]}", "", 1_000_000, 12_000_000}
             end
           end),
         true <-
           Enum.sort(Map.keys(params)) == Enum.sort(Enum.map(species, & &1["key"])) ||
             {:error, "params: one integer coefficient per species is required"},
         true <-
           Enum.all?(Map.values(params), &integer_param?/1) ||
             {:error, "params: coefficients are whole numbers (step 1)"},
         lowest when is_boolean(lowest) <- Map.get(s, "lowest_terms", true) do
      {:ok,
       %{"params" => params, "species" => species, "yield_pct" => yield_pct, "steps" => steps},
       %{"lowest_terms" => lowest}}
    else
      {:error, _} = error -> error
      _ -> {:error, "lowest_terms must be a boolean"}
    end
  end

  defp model(_other, _c, _s), do: {:error, "model must be one of: #{Enum.join(@models, ", ")}"}

  defp integer_param?(%{"min" => min, "max" => max, "step" => step, "default" => d}),
    do: Enum.all?([min, max, step, d], &(&1 == trunc(&1))) and step == 1

  # params : 1..6 entrées `nom => %{min, max, step, default, label?, unit?}` ; `spec.(nom)` donne
  # `{:ok, label, unité, min_dur, max_dur}` (bornes dures en millionièmes) ou une erreur.
  defp params(params, spec) when is_map(params) and map_size(params) in 1..6 do
    Enum.reduce_while(params, {:ok, %{}}, fn {name, p}, {:ok, acc} ->
      case param(name, p, spec.(name)) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, name, normalized)}}
        error -> {:halt, error}
      end
    end)
  end

  defp params(_params, _spec), do: {:error, "params: 1 to 6 parameters are required"}

  defp param(name, %{} = p, {:ok, label, unit, lo, hi}) do
    with {:ok, [min, max, step, default]} <-
           fixed_numbers([p["min"], p["max"], p["step"], p["default"]]),
         true <- min >= lo and max <= hi and min < max and step > 0,
         true <- div(max - min, step) <= 10_000 and rem(max - min, step) == 0,
         true <- default >= min and default <= max and rem(default - min, step) == 0,
         {:ok, label} <- text(p["label"] || label, 1, 60, "label"),
         {:ok, unit} <- text(p["unit"] || unit, 0, 20, "unit") do
      {:ok,
       %{
         "min" => p["min"],
         "max" => p["max"],
         "step" => p["step"],
         "default" => p["default"],
         "label" => label,
         "unit" => unit
       }}
    else
      _ ->
        {:error,
         "params.#{name}: min < max within #{lo / @scale}..#{hi / @scale}, step > 0 dividing the range, default on the grid"}
    end
  end

  defp param(name, _p, _spec), do: {:error, "params.#{name}: unknown parameter for this model"}

  defp fixed(fixed, params, hard) when is_map(fixed) do
    Enum.reduce_while(fixed, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      with true <- Map.has_key?(@orbit_inputs, name) and not Map.has_key?(params, name),
           {:ok, [u]} <- fixed_numbers([value]),
           {lo, hi} = hard[name],
           true <- u in lo..hi do
        {:cont, {:ok, Map.put(acc, name, value)}}
      else
        _ -> {:halt, {:error, "fixed.#{name}: unknown, already a parameter, or out of bounds"}}
      end
    end)
  end

  defp fixed(_fixed, _params, _hard), do: {:error, "fixed must be an object"}

  defp species(list) when is_list(list) and length(list) in 2..6 do
    parsed =
      Enum.map(list, fn s ->
        s = if is_map(s), do: s, else: %{}

        with {:ok, key} <- key(s["key"]),
             {:ok, formula} <- text(s["formula"], 1, 20, "formula"),
             {:ok, atoms} <- parse_formula(formula),
             side when side in ["reactant", "product"] <- s["side"],
             {:ok, [initial_u]} <- fixed_numbers([s["initial"] || 0]),
             true <- initial_u in 0..1_000_000_000 do
          {:ok,
           %{
             "key" => key,
             "formula" => formula,
             "side" => side,
             "atoms" => atoms,
             "initial" => s["initial"] || 0
           }}
        else
          _ -> :error
        end
      end)

    with true <- Enum.all?(parsed, &match?({:ok, _}, &1)),
         species = Enum.map(parsed, &elem(&1, 1)),
         sides = Enum.map(species, & &1["side"]),
         true <- "reactant" in sides and "product" in sides,
         true <- length(Enum.uniq_by(species, & &1["key"])) == length(species),
         true <- length(elements(species)) <= 6 do
      {:ok, species}
    else
      _ ->
        {:error,
         "species: 2 to 6 distinct keys, formulas like H2O (no parentheses), reactant and product sides, initial 0..1000 mol, at most 6 elements"}
    end
  end

  defp species(_list), do: {:error, "species: 2 to 6 species are required"}

  defp key(k) when is_binary(k),
    do: if(k =~ ~r/^[a-z][a-z0-9_]{0,15}$/, do: {:ok, k}, else: :error)

  defp key(_k), do: :error

  @doc "Formule chimique sans parenthèses → `{:ok, %{élément => nombre}}` (`\"H2O\"` → `%{\"H\" => 2, \"O\" => 1}`)."
  def parse_formula(formula) when is_binary(formula) do
    parts = Regex.scan(~r/([A-Z][a-z]?)(\d*)/, formula)

    with true <- formula != "" and Enum.map_join(parts, &hd/1) == formula,
         atoms =
           Enum.reduce(parts, %{}, fn [_, el, n], acc ->
             Map.update(acc, el, count(n), &(&1 + count(n)))
           end),
         true <- Enum.all?(Map.values(atoms), &(&1 in 1..20)) do
      {:ok, atoms}
    else
      _ -> :error
    end
  end

  def parse_formula(_formula), do: :error

  defp count(""), do: 1
  defp count(n), do: String.to_integer(n)

  defp elements(species),
    do: species |> Enum.flat_map(&Map.keys(&1["atoms"])) |> Enum.uniq() |> Enum.sort()

  ## Paramètres de l'apprenant

  @doc """
  Valeurs de l'apprenant (`%{nom => nombre}`, absentes = défaut) converties en requête canonique pour
  `MlLearning.Sim.Engine` : `{:ok, request, values}` ou `{:error, {:invalid, errors}}`.
  """
  def request(content, values) when is_map(values) do
    specs = content["params"] || %{}
    unknown = Map.keys(values) -- Map.keys(specs)

    errors =
      Map.new(unknown, &{"params.#{&1}", ["is not a parameter of this simulation"]})
      |> Map.merge(
        for {name, spec} <- specs,
            message = value_error(Map.get(values, name, spec["default"]), spec),
            into: %{},
            do: {"params.#{name}", [message]}
      )

    if errors == %{} do
      chosen =
        Map.new(specs, fn {name, spec} -> {name, Map.get(values, name, spec["default"])} end)

      {:ok, canonical(content, chosen), chosen}
    else
      {:error, {:invalid, errors}}
    end
  end

  def request(_content, _values),
    do: {:error, {:invalid, %{"params" => ["must be an object of numbers"]}}}

  defp value_error(value, spec) when is_number(value) do
    {:ok, [min, max, step]} = fixed_numbers([spec["min"], spec["max"], spec["step"]])

    cond do
      value < spec["min"] or value > spec["max"] or fix(value) not in min..max//1 ->
        "must be between #{spec["min"]} and #{spec["max"]}"

      not exact?(value) ->
        "must have at most 6 decimals"

      rem(fix(value) - min, step) != 0 ->
        "must be #{spec["min"]} plus a multiple of #{spec["step"]}"

      true ->
        nil
    end
  end

  defp value_error(_value, _spec), do: "must be a number"

  defp canonical(%{"model" => "orbit"} = c, chosen) do
    inputs =
      Map.new(@orbit_inputs, fn {name, {_, _, default}} ->
        {name, fix(chosen[name] || c["fixed"][name] || default)}
      end)

    Map.merge(inputs, %{"model" => "orbit", "steps" => c["steps"]})
  end

  defp canonical(%{"model" => "reaction"} = c, chosen) do
    els = elements(c["species"])

    %{
      "model" => "reaction",
      "coefficients" => Enum.map(c["species"], &trunc(chosen[&1["key"]])),
      "sides" => Enum.map(c["species"], &if(&1["side"] == "reactant", do: -1, else: 1)),
      "atoms" => Enum.map(c["species"], fn s -> Enum.map(els, &Map.get(s["atoms"], &1, 0)) end),
      "initial" => Enum.map(c["species"], &fix(&1["initial"])),
      "yield_pct" => c["yield_pct"],
      "steps" => c["steps"]
    }
  end

  ## Calcul, présentation, objectif

  @doc "Calcule et présente : `{:ok, réponse de /simulate, résultat canonique}` ou `{:error, _}`."
  def simulate(content, values, opts \\ []) do
    with {:ok, request, chosen} <- request(content, values),
         {:ok, result, engine} <- Engine.run(request, opts) do
      {:ok, present(content, chosen, result, engine), result}
    else
      {:error, :out_of_bounds} -> {:error, {:invalid, %{"params" => ["out of bounds"]}}}
      error -> error
    end
  end

  @doc "Réponse de `POST /simulate` : colonnes, trames (≤ 200), indice de tracé, métriques, description."
  def present(%{"model" => "orbit"}, _chosen, %{"frames" => frames, "metrics" => m}, engine) do
    metrics = %{
      "eccentricity" => m["eccentricity"] / @scale,
      "r_min" => m["r_min"] / @scale,
      "r_max" => m["r_max"] / @scale,
      "revolutions" => m["revolutions"],
      "period" => m["period"] && m["period"] / @scale,
      "energy" => m["energy"] / @scale,
      "bound" => m["bound"],
      "collided" => m["collided"],
      "escaped" => m["escaped"],
      "steps_run" => m["steps_run"]
    }

    %{
      "model" => "orbit",
      "engine" => engine,
      "columns" => [
        column("t", "Time", "yr"),
        column("x", "x", "AU"),
        column("y", "y", "AU"),
        column("r", "Distance", "AU")
      ],
      "frames" => Enum.map(frames, fn frame -> Enum.map(frame, &(&1 / @scale)) end),
      "plot" => %{"type" => "path", "x" => "x", "y" => "y"},
      "metrics" => metrics,
      "description" => orbit_description(metrics, List.last(frames))
    }
  end

  def present(%{"model" => "reaction"} = c, chosen, %{"frames" => frames, "metrics" => m}, engine) do
    species = c["species"]
    els = elements(species)
    by_element = fn list -> els |> Enum.zip(list) |> Map.new() end

    metrics = %{
      "atoms_left" => by_element.(m["atoms_left"]),
      "atoms_right" => by_element.(m["atoms_right"]),
      "balanced" => m["balanced"],
      "lowest_terms" => m["lowest_terms"],
      "drift" => by_element.(Enum.map(m["drift"], &(&1 / @scale))),
      "theoretical" => m["theoretical"] / @scale,
      "formed" => m["formed"] / @scale,
      "yield" => m["yield_permille"] / 1000,
      "limiting" => Enum.at(species, m["limiting"])["formula"]
    }

    %{
      "model" => "reaction",
      "engine" => engine,
      "columns" =>
        [column("pass", "Pass", "")] ++
          Enum.map(species, &column(&1["key"], &1["formula"], "mol")) ++
          Enum.map(els, &column("atoms_" <> &1, "#{&1} atoms", "mol")),
      "frames" =>
        Enum.map(frames, fn [pass | values] -> [pass | Enum.map(values, &(&1 / @scale))] end),
      "plot" => %{"type" => "lines", "x" => "pass", "y" => Enum.map(species, & &1["key"])},
      "metrics" => metrics,
      "description" => reaction_description(c, chosen, metrics)
    }
  end

  @doc "Vérifie l'objectif de la simulation avec le critère du serveur."
  def evaluate(%{"model" => "orbit"}, criterion, %{"metrics" => m}) do
    e = m["eccentricity"] / @scale

    cond do
      m["collided"] ->
        miss("The planet fell into its star: it was too slow for its orbit.", "orbit_collided")

      m["escaped"] or not m["bound"] ->
        miss(
          "The planet escaped: it was too fast for the star's gravity to hold it.",
          "orbit_escaped"
        )

      m["revolutions"] < criterion["min_revolutions"] ->
        miss(
          "The planet did not complete enough full orbits in the simulated time.",
          "orbit_few_turns"
        )

      e > criterion["max_eccentricity"] ->
        miss(
          "The orbit closes, but it is too elongated (eccentricity #{num(e, 3)}): adjust the speed to make it rounder.",
          "orbit_elongated",
          %{"eccentricity" => num(e, 3)}
        )

      true ->
        period = num(m["period"] / @scale, 2)

        %{
          correct: true,
          feedback:
            "A stable, nearly circular orbit: eccentricity #{num(e, 3)}, one turn every #{period} years.",
          feedback_code: "orbit_stable",
          feedback_params: %{"eccentricity" => num(e, 3), "period" => period}
        }
    end
  end

  def evaluate(%{"model" => "reaction"} = c, criterion, %{"metrics" => m}) do
    els = elements(c["species"])

    cond do
      not m["balanced"] ->
        {el, l, r} =
          [els, m["atoms_left"], m["atoms_right"]]
          |> Enum.zip()
          |> Enum.find(fn {_, l, r} -> l != r end)

        miss(
          "Not balanced yet: #{el} has #{l} atom(s) on the left and #{r} on the right. Atoms are never created or destroyed.",
          "reaction_unbalanced",
          %{"element" => el, "left" => l, "right" => r}
        )

      criterion["lowest_terms"] and not m["lowest_terms"] ->
        miss(
          "Every atom is conserved, but the coefficients share a common factor: use the smallest whole numbers.",
          "reaction_common_factor"
        )

      true ->
        %{
          correct: true,
          feedback: "Every atom is conserved: the equation is balanced.",
          feedback_code: "reaction_balanced",
          feedback_params: %{}
        }
    end
  end

  defp miss(feedback, code, params \\ %{}),
    do: %{correct: false, feedback: feedback, feedback_code: code, feedback_params: params}

  defp orbit_description(m, [t_u | _]) do
    t = num(t_u / @scale, 2)

    cond do
      m["collided"] ->
        "The planet fell into its star after #{t} years. Closest distance #{num(m["r_min"], 3)} AU."

      m["escaped"] ->
        "The planet escaped beyond 100 AU after #{t} years: the star's gravity could not hold it."

      true ->
        turns =
          case m["revolutions"] do
            0 -> "did not complete a full orbit"
            1 -> "completed 1 full orbit"
            n -> "completed #{n} full orbits"
          end

        period = if m["period"], do: " (one turn every #{num(m["period"], 2)} years)", else: ""

        "In #{t} years the planet #{turns}#{period}. Its distance from the star stayed between " <>
          "#{num(m["r_min"], 3)} and #{num(m["r_max"], 3)} AU: eccentricity #{num(m["eccentricity"], 3)} " <>
          "(0 is a perfect circle)."
    end
  end

  defp reaction_description(c, chosen, m) do
    side = fn which ->
      c["species"]
      |> Enum.filter(&(&1["side"] == which))
      |> Enum.map_join(" + ", fn s ->
        case trunc(chosen[s["key"]]) do
          1 -> s["formula"]
          n -> "#{n} #{s["formula"]}"
        end
      end)
    end

    counts = fn atoms -> Enum.map_join(atoms, ", ", fn {el, n} -> "#{el} #{n}" end) end

    conservation =
      if m["balanced"],
        do: "Every atom is conserved.",
        else: "Atoms are not conserved: the totals drift from pass to pass."

    product = Enum.find(c["species"], &(&1["side"] == "product"))

    "#{side.("reactant")} → #{side.("product")}. Atoms on the left: #{counts.(m["atoms_left"])}; " <>
      "on the right: #{counts.(m["atoms_right"])}. #{conservation} After #{c["steps"]} passes at " <>
      "#{c["yield_pct"]}% per pass, #{num(m["formed"], 2)} mol of #{product["formula"]} formed " <>
      "(#{round(m["yield"] * 100)}% of the #{num(m["theoretical"], 2)} mol possible; limiting reactant: #{m["limiting"]})."
  end

  defp column(key, label, unit), do: %{"key" => key, "label" => label, "unit" => unit}

  ## Nombres

  defp fix(value), do: round(value * @scale)
  defp exact?(value), do: abs(value * @scale - round(value * @scale)) < 1.0e-3

  defp fixed_numbers(values) do
    if Enum.all?(values, &(is_number(&1) and abs(&1) <= 1.0e9 and exact?(&1))),
      do: {:ok, Enum.map(values, &fix/1)},
      else: :error
  end

  defp num(x, decimals), do: :erlang.float_to_binary(x * 1.0, decimals: decimals)

  defp text(v, min, max, field) when is_binary(v) do
    t = String.trim(v)

    if String.length(t) in min..max,
      do: {:ok, t},
      else: {:error, "#{field} must be #{min} to #{max} characters"}
  end

  defp text(_v, _min, _max, field), do: {:error, "#{field} must be a string"}

  defp int(v, min, max, _field) when is_integer(v) and v >= min and v <= max, do: {:ok, v}
  defp int(_v, min, max, field), do: {:error, "#{field} must be an integer from #{min} to #{max}"}

  defp number(v, min, max, _field) when is_number(v) and v >= min and v <= max, do: {:ok, v}

  defp number(_v, min, max, field),
    do: {:error, "#{field} must be a number from #{min} to #{max}"}
end
