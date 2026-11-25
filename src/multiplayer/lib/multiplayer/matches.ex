defmodule MlMultiplayer.Matches do
  @moduledoc """
  Persistance des parties : création (événement `match_started`), rejeu du journal `match_events` et
  écriture des événements validés par le moteur, sous verrou de la ligne `matches` et contrôle de séquence.
  """
  import Ecto.Query

  alias MlMultiplayer.{
    Lobby,
    Match,
    MatchEvent,
    MatchServer,
    Member,
    Repo,
    Reward,
    Rewards,
    RuneRelay
  }

  @doc "Crée la partie et son premier événement, dans la transaction de démarrage du salon."
  def create!(%Lobby{} = lobby, players, seed) do
    start = RuneRelay.start_event(seed, players)
    match = Repo.insert!(%Match{lobby_id: lobby.id, status: "active", last_seq: 1})

    Repo.insert!(%MatchEvent{
      match_id: match.id,
      seq: 1,
      type: start["type"],
      payload: start["payload"]
    })

    match
  end

  @doc "État reconstruit par rejeu complet du journal : `{:ok, état, dernière séquence}` ou `{:error, :not_found}`."
  def replay(match_id) do
    case Repo.all(from e in MatchEvent, where: e.match_id == ^match_id, order_by: e.seq) do
      [] ->
        {:error, :not_found}

      events ->
        state = events |> Enum.map(&MatchEvent.to_engine/1) |> RuneRelay.replay()
        {:ok, state, List.last(events).seq}
    end
  end

  @doc "Ajoute des événements au journal s'il en est toujours à `expected_seq`, sinon renvoie `{:error, :conflict}`."
  def commit(match_id, expected_seq, events, state) do
    Repo.transact(fn ->
      match = Repo.one!(from m in Match, where: m.id == ^match_id, lock: "FOR UPDATE")

      if match.last_seq != expected_seq do
        {:error, :conflict}
      else
        now = DateTime.utc_now()

        rows =
          for {event, seq} <- Enum.with_index(events, expected_seq + 1) do
            %{
              match_id: match_id,
              seq: seq,
              type: event["type"],
              user_id: event["user_id"],
              payload: event["payload"],
              inserted_at: now
            }
          end

        Repo.insert_all(MatchEvent, rows)
        finished? = state.status != "active"

        Repo.update_all(from(m in Match, where: m.id == ^match_id),
          set:
            [last_seq: expected_seq + length(events), status: state.status, updated_at: now] ++
              if(finished?, do: [finished_at: now], else: [])
        )

        if finished? do
          # un salon fermé entre-temps (tout le monde est parti) le reste
          Repo.update_all(
            from(l in Lobby, where: l.id == ^match.lobby_id and l.status == "playing"),
            set: [status: "waiting", updated_at: now]
          )

          Repo.update_all(from(m in Member, where: m.lobby_id == ^match.lobby_id),
            set: [ready: false]
          )
        end

        if state.status == "won", do: {:ok, _} = Rewards.finalize(match_id)
        {:ok, match.lobby_id}
      end
    end)
  end

  @doc "Vue de la dernière partie du salon pour `user_id` (ses indices seulement), ou `nil`."
  def view(%Lobby{current_match_id: nil}, _user_id), do: nil

  def view(%Lobby{current_match_id: id}, user_id) do
    match = Repo.get!(Match, id)

    {:ok, state} =
      if match.status == "active",
        do: MatchServer.state(id),
        else: with({:ok, state, _seq} <- replay(id), do: {:ok, state})

    reward = Repo.get_by(Reward, match_id: id, user_id: user_id)

    state
    |> RuneRelay.view(user_id)
    |> Map.merge(%{
      "id" => id,
      "started_at" => match.inserted_at,
      "finished_at" => match.finished_at,
      "xp_reward" => Rewards.amount(),
      "my_reward" => reward && %{"amount" => reward.amount, "status" => reward.status}
    })
  end
end
