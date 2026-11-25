defmodule MlMultiplayer.MatchServer do
  @moduledoc """
  Processus d'une partie, seul écrivain de son journal ; il se reconstruit en rejouant `match_events`.
  """
  use GenServer, restart: :temporary
  alias MlMultiplayer.{Lobbies, Match, Matches, Repo, RuneRelay, Sweeper}

  @registry MlMultiplayer.MatchRegistry
  @supervisor MlMultiplayer.MatchSupervisor
  @idle :timer.minutes(10)

  def start_link(match_id), do: GenServer.start_link(__MODULE__, match_id, name: via(match_id))
  defp via(match_id), do: {:via, Registry, {@registry, match_id}}

  # Le Registry nettoie ses entrées de façon asynchrone : un processus mort n'y compte pas.
  def whereis(match_id) do
    case Registry.lookup(@registry, match_id) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @doc "État du moteur (usage interne : ne quitte le service qu'au travers de `RuneRelay.view/2`)."
  def state(match_id), do: call(match_id, :state)

  @doc "Intention d'un joueur : proposer une séquence (tout est revalidé ici)."
  def propose(match_id, user_id, sequence),
    do: call(match_id, {:decide, user_id, {:propose, sequence}})

  def set_absent(match_id, user_id, absent?),
    do: call(match_id, {:decide, user_id, {:absent, absent?}})

  def abort(match_id, reason), do: call(match_id, {:decide, nil, {:abort, reason}})

  # Le processus a pu s'arrêter entre la recherche et l'appel (fin de partie, inactivité) : on le relance.
  defp call(match_id, message, attempts \\ 3) do
    with {:ok, pid} <- ensure_started(match_id) do
      try do
        GenServer.call(pid, message)
      catch
        :exit, {reason, _} when attempts > 1 and reason in [:noproc, :normal, :shutdown] ->
          call(match_id, message, attempts - 1)
      end
    end
  end

  defp ensure_started(match_id) do
    with nil <- whereis(match_id) do
      case DynamicSupervisor.start_child(@supervisor, {__MODULE__, match_id}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        _ -> {:error, :not_found}
      end
    else
      pid -> {:ok, pid}
    end
  end

  @impl true
  def init(match_id) do
    with %Match{lobby_id: lobby_id} <- Repo.get(Match, match_id),
         {:ok, state, seq} <- Matches.replay(match_id) do
      {:ok, %{id: match_id, lobby_id: lobby_id, state: state, seq: seq}, @idle}
    else
      _ -> :ignore
    end
  end

  @impl true
  def handle_call(:state, _from, s), do: reply({:ok, s.state}, s)

  def handle_call({:decide, user_id, intent}, _from, s) do
    case RuneRelay.decide(s.state, user_id, intent) do
      {:ok, []} ->
        reply(:ok, s)

      {:ok, events} ->
        state = Enum.reduce(events, s.state, &RuneRelay.apply_event(&2, &1))

        case Matches.commit(s.id, s.seq, events, state) do
          {:ok, _lobby_id} ->
            Lobbies.changed(s.lobby_id)
            if state.status == "won", do: Sweeper.deliver_now()
            reply(:ok, %{s | state: state, seq: s.seq + length(events)})

          {:error, :conflict} ->
            {:ok, state, seq} = Matches.replay(s.id)
            reply({:error, :conflict}, %{s | state: state, seq: seq})
        end

      {:error, _reason} = error ->
        reply(error, s)
    end
  end

  @impl true
  def handle_info(:timeout, s), do: {:stop, :normal, s}

  defp reply(reply, %{state: %{status: "active"}} = s), do: {:reply, reply, s, @idle}
  defp reply(reply, s), do: {:stop, :normal, reply, s}
end
