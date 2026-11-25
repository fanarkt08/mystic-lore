defmodule MlLearning.Minigame do
  @moduledoc """
  Mini-jeux `sequence` et `constellation`, corrigés côté serveur en rejouant les coups.
  L'état initial est mélangé par apprenant : rien ne trahit l'ordre attendu.
  """

  @max_moves %{"sequence" => 300, "constellation" => 40}

  ## Construction (seeds, import) : la liste donnée est dans l'ordre attendu

  @doc "Construit le contenu public et la solution d'un mini-jeu à partir de sa liste dans l'ordre attendu."
  def build(%{"game" => "sequence"} = g) do
    with {:ok, prompt} <- prompt(g["prompt"]),
         {:ok, labels} <- labels(g["items"], 3..10, 200) do
      items = Enum.map(labels, &%{"id" => id(&1), "label" => &1})

      if unique_ids?(items),
        do:
          {:ok,
           %{
             "game" => "sequence",
             "prompt" => prompt,
             "items" => Enum.sort_by(items, & &1["id"])
           }, %{"order" => Enum.map(items, & &1["id"])}},
        else: {:error, "items: labels must be distinct"}
    end
  end

  def build(%{"game" => "constellation"} = g) do
    with {:ok, prompt} <- prompt(g["prompt"]),
         {:ok, stars} <- stars(g["stars"]),
         {:ok, path} <- path(g["path"], stars) do
      {:ok,
       %{
         "game" => "constellation",
         "prompt" => prompt,
         "stars" => Enum.sort_by(stars, & &1["id"])
       }, %{"path" => path}}
    end
  end

  def build(_game), do: {:error, "game must be sequence or constellation"}

  defp prompt(p) when is_binary(p) do
    p = String.trim(p)
    if String.length(p) in 1..500, do: {:ok, p}, else: {:error, "prompt: 1 to 500 characters"}
  end

  defp prompt(_p), do: {:error, "prompt: 1 to 500 characters"}

  defp labels(list, range, max) when is_list(list) do
    labels = Enum.map(list, &if(is_binary(&1), do: String.trim(&1), else: ""))

    if length(labels) in range and Enum.all?(labels, &(String.length(&1) in 1..max)) and
         length(Enum.uniq(labels)) == length(labels),
       do: {:ok, labels},
       else:
         {:error,
          "items: #{range.first} to #{range.last} distinct labels of 1 to #{max} characters"}
  end

  defp labels(_list, range, max), do: labels([], range, max)

  defp stars(list) when is_list(list) and length(list) in 3..12 do
    stars =
      for s <- list, is_map(s) do
        name = if is_binary(s["name"]), do: String.trim(s["name"]), else: ""
        %{"id" => id(name), "name" => name, "x" => s["x"], "y" => s["y"]}
      end

    valid =
      length(stars) == length(list) and
        Enum.all?(stars, fn s ->
          String.length(s["name"]) in 1..60 and coord?(s["x"]) and coord?(s["y"])
        end) and length(Enum.uniq_by(stars, & &1["name"])) == length(stars) and unique_ids?(stars)

    if valid,
      do: {:ok, stars},
      else:
        {:error, "stars: 3 to 12 distinct names (1 to 60 characters) with x and y from 0 to 100"}
  end

  defp stars(_list), do: {:error, "stars: 3 to 12 stars are required"}

  defp coord?(v), do: is_integer(v) and v in 0..100

  defp path(names, stars) when is_list(names) and length(names) in 2..20 do
    by_name = Map.new(stars, &{&1["name"], &1["id"]})
    ids = Enum.map(names, &by_name[is_binary(&1) && String.trim(&1)])

    if Enum.all?(ids, & &1) and
         Enum.all?(Enum.chunk_every(ids, 2, 1, :discard), fn [a, b] -> a != b end),
       do: {:ok, ids},
       else: {:error, "path: 2 to 20 names of the stars, never the same star twice in a row"}
  end

  defp path(_names, _stars), do: {:error, "path: 2 to 20 star names are required"}

  defp id(label),
    do: :crypto.hash(:sha256, label) |> Base.encode16(case: :lower) |> binary_part(0, 8)

  defp unique_ids?(items), do: length(Enum.uniq_by(items, & &1["id"])) == length(items)

  ## Présentation (état initial mélangé par apprenant)

  @doc "`content` exposé à `user_id` : éléments (ou étoiles) dans l'ordre initial mélangé pour cet apprenant."
  def public(%{kind: "minigame", content: %{"game" => "sequence"} = c} = lesson, user_id),
    do: Map.put(c, "items", initial(lesson, user_id))

  def public(%{kind: "minigame", content: %{"game" => "constellation"} = c} = lesson, user_id),
    do: Map.put(c, "stars", shuffle(c["stars"], lesson.id, user_id))

  def public(%{content: content}, _user_id), do: content

  defp initial(%{content: %{"items" => items}, solution: %{"order" => order}, id: id}, user_id) do
    shuffled = shuffle(items, id, user_id)
    # jamais l'ordre attendu : décalage d'un cran si le mélange le redonne
    if Enum.map(shuffled, & &1["id"]) == order,
      do: tl(shuffled) ++ [hd(shuffled)],
      else: shuffled
  end

  defp shuffle(list, lesson_id, user_id),
    do: Enum.sort_by(list, &:crypto.hash(:sha256, "#{user_id}:#{lesson_id}:#{&1["id"]}"))

  ## Correction

  @doc "`{:ok, %{correct, score, feedback, trace: nil}}` ou `{:error, {:invalid, errors}}`."
  def grade(%{content: %{"game" => game}} = lesson, user_id, answer) when is_binary(answer) do
    with {:ok, moves} <- moves(answer, @max_moves[game]) do
      grade(game, lesson, user_id, moves)
    end
  end

  defp moves(answer, max) do
    case Jason.decode(answer) do
      {:ok, %{"moves" => moves}} when is_list(moves) and length(moves) <= max -> {:ok, moves}
      _ -> invalid("must be a JSON object {\"moves\": [...]} with at most #{max} moves")
    end
  end

  defp grade("sequence", lesson, user_id, moves) do
    start = Enum.map(initial(lesson, user_id), & &1["id"])
    order = lesson.solution["order"]

    with {:ok, final} <- replay(start, moves) do
      placed = Enum.count(Enum.zip(final, order), fn {a, b} -> a == b end)
      n = length(order)

      feedback =
        if placed == n,
          do:
            "Everything is in the right order, in #{length(moves)} move(s) (fewest possible: #{inversions(start, order)}).",
          else: "#{placed} of #{n} items are in the right place. Keep going!"

      {:ok, result(placed == n, round(placed * 100 / n), feedback)}
    end
  end

  defp grade("constellation", lesson, _user_id, path) do
    ids = MapSet.new(lesson.content["stars"], & &1["id"])
    expected = lesson.solution["path"]

    if Enum.all?(path, &(is_binary(&1) and MapSet.member?(ids, &1))) do
      matching = Enum.count(Enum.zip(path, expected), fn {a, b} -> a == b end)
      n = max(length(expected), length(path))

      feedback =
        cond do
          path == expected -> "The constellation shines: every star is linked in the right order."
          path == [] -> "Select the stars in order to draw the constellation."
          true -> "#{matching} of #{length(expected)} stars are in the right place in your path."
        end

      {:ok, result(path == expected, round(matching * 100 / n), feedback)}
    else
      invalid("moves must be star ids of this map")
    end
  end

  defp replay(order, moves) do
    Enum.reduce_while(moves, {:ok, order}, fn
      %{"id" => id, "dir" => dir}, {:ok, acc} when dir in ["up", "down"] ->
        i = Enum.find_index(acc, &(&1 == id))
        j = if i, do: if(dir == "up", do: i - 1, else: i + 1)

        if i && j in 0..(length(acc) - 1)//1,
          do:
            {:cont, {:ok, acc |> List.replace_at(i, Enum.at(acc, j)) |> List.replace_at(j, id)}},
          else: {:halt, invalid("contains an impossible move")}

      _move, _acc ->
        {:halt, invalid("each move is {\"id\", \"dir\": \"up\" | \"down\"}")}
    end)
  end

  # nombre minimal d'échanges de voisins = nombre d'inversions par rapport à l'ordre attendu
  defp inversions(start, order) do
    rank = order |> Enum.with_index() |> Map.new()
    ranks = Enum.map(start, &rank[&1])

    for {a, i} <- Enum.with_index(ranks),
        {b, j} <- Enum.with_index(ranks),
        i < j,
        a > b,
        reduce: 0,
        do: (n -> n + 1)
  end

  defp result(correct, score, feedback),
    do: %{correct: correct, score: score, feedback: feedback, trace: nil}

  defp invalid(message), do: {:error, {:invalid, %{answer: [message]}}}
end
