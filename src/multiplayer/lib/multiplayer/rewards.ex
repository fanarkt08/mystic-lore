defmodule MlMultiplayer.Rewards do
  @moduledoc """
  Récompense de victoire de 50 XP livrée à learning, exactement une fois par joueur.
  Un échec est relancé plus tard, même après un redémarrage : jamais de perte silencieuse.
  """
  import Ecto.Query
  require Logger
  alias MlMultiplayer.{Lobbies, Match, Matches, Member, Repo, Reward}

  @amount 50
  @batch 20
  @lease 60
  @max_delay 600

  def amount, do: @amount

  @doc "Crée les récompenses d'une partie gagnée (idempotent) : `{:ok, lignes créées}`."
  def finalize(match_id, now \\ DateTime.utc_now()) do
    Repo.transact(fn ->
      with %Match{status: "won", lobby_id: lobby_id} <-
             Repo.one(from m in Match, where: m.id == ^match_id, lock: "FOR UPDATE"),
           {:ok, state, _seq} <- Matches.replay(match_id) do
        members =
          Repo.all(
            from m in Member,
              where: m.lobby_id == ^lobby_id and m.status == "active",
              select: m.user_id
          )

        rows =
          for user_id <- state.players, user_id not in state.absent, user_id in members do
            %{
              id: Ecto.UUID.generate(),
              match_id: match_id,
              user_id: user_id,
              amount: @amount,
              status: "pending",
              attempts: 0,
              next_attempt_at: now,
              inserted_at: now,
              updated_at: now
            }
          end

        {created, _} =
          Repo.insert_all(Reward, rows,
            on_conflict: :nothing,
            conflict_target: [:match_id, :user_id]
          )

        {:ok, created}
      else
        _ -> {:ok, 0}
      end
    end)
  end

  @doc "Livre les récompenses dues à `now` (20 au plus) et renvoie les statuts obtenus."
  def deliver_due(now \\ DateTime.utc_now()) do
    {:ok, due} =
      Repo.transact(fn ->
        due =
          Repo.all(
            from r in Reward,
              where: r.status == "pending" and r.next_attempt_at <= ^now,
              order_by: r.next_attempt_at,
              limit: @batch,
              lock: "FOR UPDATE SKIP LOCKED"
          )

        Repo.update_all(from(r in Reward, where: r.id in ^Enum.map(due, & &1.id)),
          set: [next_attempt_at: DateTime.add(now, @lease)]
        )

        {:ok, due}
      end)

    statuses = Enum.map(due, &deliver(&1, now))
    match_ids = due |> Enum.map(& &1.match_id) |> Enum.uniq()

    # la vue de la partie affiche l'état de la récompense de chacun
    for lobby_id <- Repo.all(from m in Match, where: m.id in ^match_ids, select: m.lobby_id),
        do: Lobbies.changed(lobby_id)

    statuses
  end

  defp deliver(reward, now) do
    body = %{
      user_id: reward.user_id,
      ref_key: "multiplayer:match:#{reward.match_id}",
      amount: reward.amount
    }

    attempts = reward.attempts + 1

    {status, changes} =
      case MlShared.Client.post(:learning, "/api/internal/xp", json: body) do
        {:ok, %{"xp" => xp}} when xp in ["awarded", "duplicate"] ->
          {"awarded", [status: "awarded", awarded_at: now, last_error: nil]}

        {:error, {:http, 422, _body}} ->
          {"failed", [status: "failed", last_error: "rejected by learning (422)"]}

        other ->
          retry_at = DateTime.add(now, min(5 * Integer.pow(2, attempts - 1), @max_delay))
          {"pending", [last_error: failure(other), next_attempt_at: retry_at]}
      end

    if status != "awarded",
      do:
        Logger.warning(
          "multiplayer reward #{reward.id} (match #{reward.match_id}) #{status} after attempt #{attempts}"
        )

    Repo.update_all(from(r in Reward, where: r.id == ^reward.id),
      set: changes ++ [attempts: attempts, updated_at: now]
    )

    status
  end

  defp failure({:error, :unavailable}), do: "learning unavailable"
  defp failure({:error, {:http, status, _body}}), do: "learning answered #{status}"
  defp failure(_other), do: "unexpected answer from learning"
end
