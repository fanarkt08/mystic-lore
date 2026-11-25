defmodule MlMultiplayer.RuneRelay do
  @moduledoc """
  Moteur pur et déterministe de « The Rune Relay », sans E/S ni processus.
  Un joueur ne voit que ses propres indices, et le secret seulement une fois la partie terminée.
  """

  @runes 8
  @length 5
  @max_attempts 6

  def rune_count, do: @runes
  def sequence_length, do: @length

  ## Génération

  @doc "Événement `match_started` : ordre de jeu, séquence secrète et indices, entièrement déterminés par `seed`."
  def start_event(seed, players)
      when is_integer(seed) and is_list(players) and length(players) in 2..4 do
    rand = :rand.seed_s(:exsss, seed)
    {order, rand} = shuffle(players, rand)
    {runes, rand} = shuffle(Enum.to_list(0..(@runes - 1)), rand)
    secret = Enum.take(runes, @length)
    {facts, _rand} = shuffle(facts(secret), rand)

    %{
      "type" => "match_started",
      "user_id" => nil,
      "payload" => %{
        "seed" => seed,
        "players" => order,
        "secret" => secret,
        "hints" => deal(facts, order),
        "max_attempts" => @max_attempts
      }
    }
  end

  # Les 5 faits `at` identifient la séquence : la sélection aboutit toujours à une solution unique.
  defp facts(secret) do
    indexed = Enum.with_index(secret)

    for({rune, pos} <- indexed, do: %{"kind" => "at", "pos" => pos, "rune" => rune}) ++
      for(rune <- secret, do: %{"kind" => "present", "rune" => rune}) ++
      for(
        rune <- Enum.to_list(0..(@runes - 1)) -- secret,
        do: %{"kind" => "absent", "rune" => rune}
      ) ++
      for(
        {a, i} <- indexed,
        {b, j} <- indexed,
        i < j,
        do: %{"kind" => "before", "a" => a, "b" => b}
      ) ++
      for(
        {rune, i} <- indexed,
        pos <- 0..(@length - 1),
        pos != i,
        do: %{"kind" => "not_at", "pos" => pos, "rune" => rune}
      )
  end

  # Garde (dans l'ordre mélangé) chaque fait qui élimine encore des candidates, jusqu'à n'en laisser qu'une,
  # puis distribue les indices à tour de rôle : chaque joueur en reçoit au moins un.
  defp deal(facts, players) do
    {chosen, _candidates} =
      Enum.reduce(facts, {[], candidates()}, fn fact, {chosen, candidates} ->
        narrowed =
          if match?([_], candidates),
            do: candidates,
            else: Enum.filter(candidates, &holds?(fact, &1))

        if length(narrowed) < length(candidates),
          do: {[fact | chosen], narrowed},
          else: {chosen, candidates}
      end)

    chosen = Enum.reverse(chosen)
    clues = chosen ++ Enum.take(facts -- chosen, max(length(players) - length(chosen), 0))
    count = length(players)

    players
    |> Enum.with_index()
    |> Map.new(fn {player, seat} ->
      {player, clues |> Enum.drop(seat) |> Enum.take_every(count)}
    end)
  end

  @doc "Les 6 720 séquences possibles (5 runes distinctes parmi 8, ordonnées)."
  def candidates, do: arrangements(Enum.to_list(0..(@runes - 1)), @length)

  defp arrangements(_pool, 0), do: [[]]

  defp arrangements(pool, n),
    do: for(x <- pool, rest <- arrangements(List.delete(pool, x), n - 1), do: [x | rest])

  @doc "Vrai si l'indice est vérifié par la séquence."
  def holds?(%{"kind" => "at", "pos" => pos, "rune" => rune}, seq), do: Enum.at(seq, pos) == rune

  def holds?(%{"kind" => "not_at", "pos" => pos, "rune" => rune}, seq),
    do: Enum.at(seq, pos) != rune

  def holds?(%{"kind" => "present", "rune" => rune}, seq), do: rune in seq
  def holds?(%{"kind" => "absent", "rune" => rune}, seq), do: rune not in seq

  def holds?(%{"kind" => "before", "a" => a, "b" => b}, seq) do
    case {Enum.find_index(seq, &(&1 == a)), Enum.find_index(seq, &(&1 == b))} do
      {i, j} when is_integer(i) and is_integer(j) -> i < j
      _ -> false
    end
  end

  # Mélange déterministe (clé aléatoire tirée de l'état `rand` puis tri) ; renvoie l'état suivant.
  defp shuffle(list, rand) do
    {keyed, rand} =
      Enum.map_reduce(list, rand, fn item, rand ->
        {key, rand} = :rand.uniform_s(1_000_000_000_000, rand)
        {{key, item}, rand}
      end)

    {keyed |> Enum.sort() |> Enum.map(&elem(&1, 1)), rand}
  end

  ## État

  @doc "État initial, depuis l'événement `match_started`."
  def init(%{"type" => "match_started", "payload" => payload}) do
    %{
      status: "active",
      reason: nil,
      players: payload["players"],
      secret: payload["secret"],
      hints: payload["hints"],
      max_attempts: payload["max_attempts"],
      attempts: [],
      turn: 0,
      absent: []
    }
  end

  @doc "Rejoue un journal complet (`match_started` en tête)."
  def replay([start | events]), do: Enum.reduce(events, init(start), &apply_event(&2, &1))

  def current_player(%{status: "active", players: players, turn: turn}),
    do: Enum.at(players, turn)

  def current_player(_state), do: nil

  ## Décision

  @doc "Valide une intention et renvoie les événements à persister."
  def decide(%{status: status}, _user_id, _intent) when status != "active",
    do: {:error, :finished}

  def decide(state, user_id, {:propose, sequence}) do
    cond do
      user_id not in state.players ->
        {:error, :not_participant}

      user_id != current_player(state) ->
        {:error, :not_your_turn}

      true ->
        with {:ok, seq} <- validate(sequence) do
          n = length(state.attempts) + 1
          marks = score(state.secret, seq)

          attempt = %{
            "type" => "attempt",
            "user_id" => user_id,
            "payload" => %{
              "n" => n,
              "sequence" => seq,
              "marks" => marks,
              "hits" => Enum.count(marks, &(&1 == "hit")),
              "present" => Enum.count(marks, &(&1 == "present"))
            }
          }

          cond do
            seq == state.secret -> {:ok, [attempt, finished("won", nil)]}
            n >= state.max_attempts -> {:ok, [attempt, finished("lost", nil)]}
            true -> {:ok, [attempt]}
          end
        end
    end
  end

  def decide(state, user_id, {:absent, absent?}) when is_boolean(absent?) do
    if user_id in state.players and user_id in state.absent != absent?,
      do:
        {:ok, [%{"type" => "absence", "user_id" => user_id, "payload" => %{"absent" => absent?}}]},
      else: {:ok, []}
  end

  def decide(_state, _user_id, {:abort, reason}) when is_binary(reason),
    do: {:ok, [finished("aborted", reason)]}

  def decide(_state, _user_id, _intent), do: {:error, :invalid_intent}

  defp finished(status, reason),
    do: %{
      "type" => "match_finished",
      "user_id" => nil,
      "payload" => %{"status" => status, "reason" => reason}
    }

  @doc "Une séquence valide : exactement 5 entiers distincts de 0 à 7."
  def validate(seq) when is_list(seq) and length(seq) == @length do
    cond do
      not Enum.all?(seq, &(is_integer(&1) and &1 in 0..(@runes - 1))) ->
        {:error, :invalid_sequence}

      length(Enum.uniq(seq)) != @length ->
        {:error, :duplicate_runes}

      true ->
        {:ok, seq}
    end
  end

  def validate(_seq), do: {:error, :invalid_sequence}

  @doc "Note d'une proposition, position par position : `hit`, `present` ou `miss`."
  def score(secret, seq) do
    Enum.zip_with(secret, seq, fn s, g ->
      cond do
        s == g -> "hit"
        g in secret -> "present"
        true -> "miss"
      end
    end)
  end

  ## Application

  @doc "Applique un événement validé (en direct ou au rejeu)."
  def apply_event(state, %{"type" => "attempt", "user_id" => user_id, "payload" => payload}) do
    attempt = Map.put(payload, "user_id", user_id)
    advance(%{state | attempts: state.attempts ++ [attempt]}, 1)
  end

  def apply_event(state, %{"type" => "absence", "user_id" => user_id, "payload" => payload}) do
    absent =
      if payload["absent"],
        do: Enum.uniq(state.absent ++ [user_id]),
        else: List.delete(state.absent, user_id)

    advance(%{state | absent: absent}, 0)
  end

  def apply_event(state, %{"type" => "match_finished", "payload" => payload}),
    do: %{state | status: payload["status"], reason: payload["reason"]}

  # Donne le trait au premier joueur présent à partir de `turn + offset`.
  defp advance(%{status: "active", players: players, turn: turn} = state, offset) do
    n = length(players)

    case Enum.find(
           offset..(offset + n - 1),
           &(Enum.at(players, rem(turn + &1, n)) not in state.absent)
         ) do
      nil -> %{state | turn: rem(turn + offset, n)}
      step -> %{state | turn: rem(turn + step, n)}
    end
  end

  defp advance(state, _offset), do: state

  ## Vue

  @doc "Vue de `user_id`, sans les indices des autres ni le secret avant la fin."
  def view(state, user_id) do
    %{
      "status" => state.status,
      "reason" => state.reason,
      "players" => state.players,
      "current_player" => current_player(state),
      "attempts" => state.attempts,
      "max_attempts" => state.max_attempts,
      "attempts_left" => state.max_attempts - length(state.attempts),
      "absent" => state.absent,
      "my_hints" => Map.get(state.hints, user_id, []),
      "secret" => if(state.status != "active", do: state.secret)
    }
  end
end
