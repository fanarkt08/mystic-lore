defmodule MlMultiplayer.Social do
  @moduledoc """
  Relations lues chez social. Si social est injoignable, l'action est refusée : un joueur bloqué ne doit jamais passer.
  """
  alias MlShared.Client

  def blocked_ids(user_id) do
    case Client.get(:social, "/api/internal/blocks/:id", path_params: [id: user_id]) do
      {:ok, %{"user_ids" => ids}} when is_list(ids) -> {:ok, ids}
      _ -> {:error, :social_unavailable}
    end
  end

  @refusals %{
    "blocked" => :blocked,
    "not_friends" => :not_friends,
    "lobby_invites_closed" => :lobby_invites_closed
  }

  @doc "`:ok`, `{:error, :blocked | :not_friends | :lobby_invites_closed}` ou `{:error, :social_unavailable}`."
  def can_invite(host_id, invitee_id) do
    case Client.get(:social, "/api/internal/can-contact",
           params: [from: host_id, to: invitee_id, kind: "lobby_invite"]
         ) do
      {:ok, %{"allowed" => true}} ->
        :ok

      {:error, {:http, 403, %{"error" => code}}} when is_map_key(@refusals, code) ->
        {:error, @refusals[code]}

      _ ->
        {:error, :social_unavailable}
    end
  end

  @doc "Signale `target_id` au nom de `reporter_id` (l'identité voyage dans le jeton interne) : `{:ok, report_id}`."
  def report(reporter_id, target_id, reason, details) do
    body = %{target_type: "user", target_id: target_id, reason: reason, details: details}

    case Client.post(:social, "/api/reports", as: reporter_id, json: body) do
      {:ok, %{"id" => id}} ->
        {:ok, id}

      {:error, {:http, 422, %{"errors" => errors}}} when is_map(errors) ->
        {:error, {:invalid, errors}}

      _ ->
        {:error, :social_unavailable}
    end
  end
end
