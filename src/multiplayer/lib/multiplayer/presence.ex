defmodule MlMultiplayer.Presence do
  @moduledoc """
  Présence des joueurs par battements : déconnecté après 30 s sans battement, absent 60 s plus tard.
  """
  import Ecto.Query
  alias MlMultiplayer.{Lobbies, Lobby, Match, MatchServer, Member, Repo}

  @doc "Enregistre le battement d'un membre actif."
  def heartbeat(user_id, lobby_id, now \\ DateTime.utc_now()) do
    with {:ok, lobby, _} <- Lobbies.authorize(user_id, lobby_id, [:host, :player]) do
      member =
        from m in Member,
          where: m.lobby_id == ^lobby.id and m.user_id == ^user_id and m.status == "active"

      {back, _} =
        Repo.update_all(where(member, [m], m.connection != "online"),
          set: [connection: "online", last_seen_at: now]
        )

      if back == 0 do
        Repo.update_all(member, set: [last_seen_at: now])
      else
        reconcile(lobby.id, now)
        Lobbies.changed(lobby.id)
      end

      :ok
    end
  end

  @doc "Transitions online → disconnected → absent, puis réalignement de chaque partie en cours."
  def sweep(now \\ DateTime.utc_now()) do
    changed =
      transition(["online"], "disconnected", MlMultiplayer.rule(:disconnect_after), now) ++
        transition(["online", "disconnected"], "absent", MlMultiplayer.rule(:absent_after), now)

    for lobby_id <- Repo.all(from m in Match, where: m.status == "active", select: m.lobby_id),
        do: reconcile(lobby_id, now)

    for lobby_id <- Enum.uniq(changed), do: Lobbies.changed(lobby_id)
    :ok
  end

  defp transition(from, to, seconds, now) do
    {_, lobby_ids} =
      Repo.update_all(
        from(m in Member,
          where: m.status == "active" and m.connection in ^from,
          where: m.last_seen_at < ^DateTime.add(now, -seconds),
          select: m.lobby_id
        ),
        set: [connection: to]
      )

    lobby_ids
  end

  @doc "Aligne la partie en cours sur les membres réellement présents, ou l'interrompt."
  def reconcile(lobby_id, now \\ DateTime.utc_now()) do
    with %Lobby{current_match_id: match_id} when is_binary(match_id) <- Repo.get(Lobby, lobby_id),
         %Match{status: "active"} <- Repo.get(Match, match_id),
         {:ok, state} <- MatchServer.state(match_id) do
      members =
        Repo.all(
          from m in Member,
            where:
              m.lobby_id == ^lobby_id and m.user_id in ^state.players and m.status == "active"
        )
        |> Map.new(&{&1.user_id, &1})

      present =
        Enum.filter(
          state.players,
          &match?(%Member{connection: c} when c != "absent", members[&1])
        )

      cond do
        map_size(members) < 2 ->
          MatchServer.abort(match_id, "not_enough_players")

        present == [] and abandoned?(Map.values(members), now) ->
          MatchServer.abort(match_id, "abandoned")

        true ->
          for player <- state.players,
              player in present == player in state.absent,
              do: MatchServer.set_absent(match_id, player, player not in present)
      end
    end

    :ok
  end

  defp abandoned?(members, now) do
    last_seen = members |> Enum.map(& &1.last_seen_at) |> Enum.max(DateTime)
    DateTime.diff(now, last_seen) >= MlMultiplayer.rule(:abandon_after)
  end
end
