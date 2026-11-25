defmodule MlMultiplayer.Chat do
  @moduledoc """
  Chat d'un salon, réservé à ses membres actifs et limité à 5 messages par 10 s.
  Les messages d'un membre bloqué ne sont jamais renvoyés au lecteur.
  """
  import Ecto.Query
  alias MlMultiplayer.{Lobbies, Message, Repo, Social}
  alias MlShared.Events

  @page_size 50
  @rate_max 5
  @rate_seconds 10

  @doc "Jusqu'à 50 messages visibles par `user_id`, en ordre chronologique, antérieurs à `before` s'il est donné."
  def list(user_id, lobby_id, before) do
    with {:ok, lobby, _} <- Lobbies.authorize(user_id, lobby_id, [:host, :player]),
         {:ok, blocked} <- Social.blocked_ids(user_id),
         {:ok, cursor} <- cursor(lobby.id, before) do
      {entries, older} =
        from(m in Message,
          where: m.lobby_id == ^lobby.id and m.user_id not in ^blocked,
          order_by: [desc: m.inserted_at, desc: m.id],
          limit: ^(@page_size + 1)
        )
        |> older_than(cursor)
        |> Repo.all()
        |> Enum.split(@page_size)

      next_before = if older != [], do: List.last(entries).id
      {:ok, %{entries: Enum.reverse(entries), next_before: next_before}}
    end
  end

  defp cursor(_lobby_id, before) when before in [nil, ""], do: {:ok, nil}

  defp cursor(lobby_id, before) do
    with {:ok, id} <- MlMultiplayer.cast_uuid(before),
         %Message{} = message <- Repo.get_by(Message, id: id, lobby_id: lobby_id) do
      {:ok, message}
    else
      _ -> {:error, {:invalid, %{before: ["is invalid"]}}}
    end
  end

  defp older_than(query, nil), do: query

  defp older_than(query, %Message{inserted_at: at, id: id}),
    do: where(query, [m], m.inserted_at < ^at or (m.inserted_at == ^at and m.id < ^id))

  @doc "Publie un message (membre actif) ; `{:error, :rate_limited}` au-delà de 5 messages en 10 s."
  def post(user_id, lobby_id, attrs, now \\ DateTime.utc_now()) do
    with {:ok, lobby, _} <- Lobbies.authorize(user_id, lobby_id, [:host, :player]),
         changeset =
           Message.changeset(
             %Message{lobby_id: lobby.id, user_id: user_id, inserted_at: now},
             attrs
           ),
         {:ok, message} <-
           Repo.transact(fn -> insert_limited(changeset, lobby.id, user_id, now) end) do
      Events.broadcast(Lobbies.topic(lobby.id), {:chat_posted, lobby.id})
      {:ok, message}
    end
  end

  defp insert_limited(%{valid?: false} = changeset, _lobby_id, _user_id, _now),
    do: {:error, changeset}

  defp insert_limited(changeset, lobby_id, user_id, now) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "chat:#{lobby_id}:#{user_id}"
    ])

    since = DateTime.add(now, -@rate_seconds)

    recent =
      Repo.aggregate(
        from(m in Message,
          where: m.lobby_id == ^lobby_id and m.user_id == ^user_id and m.inserted_at > ^since
        ),
        :count
      )

    if recent >= @rate_max, do: {:error, :rate_limited}, else: Repo.insert(changeset)
  end
end
