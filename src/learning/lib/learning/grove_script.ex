defmodule MlLearning.GroveScript do
  @moduledoc """
  Interpréteur du mini-langage borné GroveScript, analysé ligne à ligne sans jamais évaluer de code Elixir.
  """

  @max_bytes 600
  @max_lines 20
  @max_iterations 10
  @max_steps 100
  @default_plants 3

  @doc "Analyse et exécute : `{:ok, [{plant, :loop | :literal}]}` dans l'ordre d'arrosage, ou `{:error, message}`."
  def run(source) when byte_size(source) > @max_bytes,
    do: {:error, "Script too long (max #{@max_bytes} bytes)."}

  def run(source) when is_binary(source) do
    lines =
      source
      |> String.split(["\r\n", "\n", "\r"])
      |> Enum.map(&(&1 |> String.split("#", parts: 2) |> hd() |> String.trim_trailing()))
      |> Enum.reject(&(&1 == ""))

    cond do
      lines == [] -> {:error, "Write at least one instruction."}
      length(lines) > @max_lines -> {:error, "Too many lines (max #{@max_lines})."}
      true -> with {:ok, program} <- parse(lines, []), do: execute(program)
    end
  end

  @doc """
  Corrige un script pour `plants` plants (2..10, défaut 3) : `%{correct, feedback, trace}`
  (`trace` = plants arrosés, `nil` si erreur).
  """
  def grade(source, plants \\ @default_plants)

  def grade(source, plants) when is_integer(plants) and plants in 2..10 do
    case run(source) do
      {:ok, events} ->
        trace = Enum.map(events, &elem(&1, 0))
        exact? = Enum.sort(trace) == Enum.to_list(0..(plants - 1))
        by_loop? = Enum.all?(events, &match?({_, :loop}, &1))

        %{
          correct: exact? and by_loop?,
          feedback: feedback(exact?, by_loop?, trace, plants),
          trace: trace
        }

      {:error, message} ->
        %{correct: false, feedback: "Script error: #{message}", trace: nil}
    end
  end

  def grade(source, _invalid), do: grade(source, @default_plants)

  defp feedback(true, true, _, n),
    do: "The grove drinks: plants #{plant_list(n)} were each watered exactly once by your loop."

  defp feedback(true, false, _, n),
    do: "Every sapling got water, but by hand. Let a for loop over range(#{n}) do the watering."

  defp feedback(false, _, trace, n),
    do:
      "You watered plants [#{Enum.join(trace, ", ")}]. Water plants #{plant_list(n)}, each exactly once, with a loop."

  # 3 → "0, 1 and 2" ; 4 → "0, 1, 2 and 3"
  defp plant_list(n) do
    {init, [last]} = Enum.split(Enum.to_list(0..(n - 1)), n - 1)
    Enum.join(init, ", ") <> " and " <> Integer.to_string(last)
  end

  ## Analyse

  defp parse([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse([line | rest], acc) do
    cond do
      indented?(line) ->
        {:error, "Unexpected indentation: #{excerpt(line)}"}

      captures = Regex.run(loop_regex(), line, capture: :all_but_first) ->
        {body, rest} = Enum.split_while(rest, &indented?/1)

        with {:ok, var, first, last} <- loop_range(captures),
             {:ok, statements} <- parse_body(body, var, []) do
          parse(rest, [{:loop, first, last, statements} | acc])
        end

      loop?(line) ->
        {:error, "Loop syntax: for plant in range(3): then an indented water(plant) line."}

      true ->
        with {:ok, statement} <- parse_water(line, nil), do: parse(rest, [statement | acc])
    end
  end

  defp loop_range([var, n]), do: loop_range([var, "0", n])

  defp loop_range([var, a, b]) do
    {first, last} = {String.to_integer(a), String.to_integer(b)}

    if last - first > @max_iterations,
      do: {:error, "range is limited to #{@max_iterations} iterations."},
      else: {:ok, var, first, last}
  end

  defp parse_body([], _var, []), do: {:error, "A loop needs an indented body."}
  defp parse_body([], _var, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_body([line | rest], var, acc) do
    line = String.trim_leading(line)

    if loop?(line),
      do: {:error, "Nested loops are not supported."},
      else: with({:ok, s} <- parse_water(line, var), do: parse_body(rest, var, [s | acc]))
  end

  defp parse_water(line, var) do
    case Regex.run(water_regex(), line, capture: :all_but_first) do
      [plant] ->
        {:ok, {:water, String.to_integer(plant)}}

      ["", ^var] ->
        {:ok, {:water, :loop}}

      ["", name] ->
        {:error, "Unknown name: #{name}. Only the loop variable can be watered by name."}

      nil ->
        {:error, "Unknown instruction: #{excerpt(line)}"}
    end
  end

  defp loop_regex,
    do:
      ~r/^for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+range\(\s*(\d{1,3})\s*(?:,\s*(\d{1,3})\s*)?\)\s*:$/

  defp water_regex, do: ~r/^water\(\s*(?:(\d{1,3})|([A-Za-z_][A-Za-z0-9_]*))\s*\)$/
  defp loop?(line), do: Regex.match?(~r/^for\b/, line)
  defp indented?(line), do: String.starts_with?(line, [" ", "\t"])
  defp excerpt(line), do: line |> String.trim() |> String.slice(0, 40)

  ## Exécution : au plus 19 arrosages × 10 itérations, puis contrôle du budget d'étapes

  defp execute(program) do
    events =
      Enum.flat_map(program, fn
        {:water, plant} -> [{plant, :literal}]
        {:loop, first, last, body} -> for i <- first..(last - 1)//1, s <- body, do: water(s, i)
      end)

    if length(events) > @max_steps,
      do: {:error, "Too many steps (max #{@max_steps})."},
      else: {:ok, events}
  end

  defp water({:water, :loop}, i), do: {i, :loop}
  defp water({:water, plant}, _i), do: {plant, :literal}
end
