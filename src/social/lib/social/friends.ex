defmodule MlSocial.Friends do
  @moduledoc """
  Amitiés, demandes d'ami et blocages, chaque écriture sous un verrou propre à la paire de membres.
  """
  import Ecto.Query
  alias MlShared.Events
  alias MlSocial.{Block, Friendship, Repo}

  ## Lecture

  @doc "Identifiants des amis de `me`."
  def friend_ids(me) do
    from(f in Friendship,
      where: f.status == "accepted" and (f.requester_id == ^me or f.addressee_id == ^me),
      select: {f.requester_id, f.addressee_id}
    )
    |> Repo.all()
    |> Enum.map(fn {requester, addressee} ->
      if requester == me, do: addressee, else: requester
    end)
  end

  @doc "Demandes en attente de `me`, les plus récentes d'abord : `{reçues, envoyées}`."
  def requests(me) do
    from(f in Friendship,
      where: f.status == "pending" and (f.requester_id == ^me or f.addressee_id == ^me),
      order_by: [desc: f.inserted_at]
    )
    |> Repo.all()
    |> Enum.split_with(&(&1.addressee_id == me))
  end

  def incoming_count(me) do
    Repo.aggregate(
      from(f in Friendship, where: f.addressee_id == ^me and f.status == "pending"),
      :count
    )
  end

  @doc "Membres bloqués par `me`, les plus récents d'abord."
  def blocked_ids(me) do
    Repo.all(
      from b in Block,
        where: b.blocker_id == ^me,
        order_by: [desc: b.inserted_at],
        select: b.blocked_id
    )
  end

  @doc "Membres avec lesquels `me` a un blocage, dans un sens ou dans l'autre (filtrage par les autres services)."
  def blocked_either_ids(me) do
    out = Repo.all(from b in Block, where: b.blocker_id == ^me, select: b.blocked_id)
    inn = Repo.all(from b in Block, where: b.blocked_id == ^me, select: b.blocker_id)
    Enum.uniq(out ++ inn)
  end

  def friends?(a, b), do: Repo.exists?(where(pair(a, b), status: "accepted"))

  @doc "Vrai si l'un des deux a bloqué l'autre."
  def blocked?(a, b) do
    Repo.exists?(
      from x in Block,
        where:
          (x.blocker_id == ^a and x.blocked_id == ^b) or
            (x.blocker_id == ^b and x.blocked_id == ^a)
    )
  end

  ## Demandes et amitiés

  @doc "Envoie une demande d'ami, ou accepte la demande inverse si elle est déjà en attente."
  def send_request(me, user_id) do
    with {:ok, other} <- other_user(me, user_id),
         {:ok, friendship} <- with_pair_lock(me, other, fn -> request_locked(me, other) end) do
      notify([me, other])

      # nouvelle demande, ou demande croisée acceptée (le demandeur d'origine est prévenu)
      if friendship.status == "pending",
        do: MlSocial.Notify.friend_request(friendship),
        else: MlSocial.Notify.friend_accepted(friendship)

      {:ok, friendship}
    end
  end

  defp request_locked(me, other) do
    if blocked?(me, other) do
      {:error, :blocked}
    else
      case Repo.one(pair(me, other)) do
        nil ->
          with :ok <- MlSocial.Settings.permission(me, other, "friend_request"),
               do: Repo.insert(%Friendship{requester_id: me, addressee_id: other})

        %Friendship{status: "accepted"} ->
          {:error, :already_friends}

        %Friendship{requester_id: ^me} ->
          {:error, :already_requested}

        inverse ->
          accept_row(inverse)
      end
    end
  end

  @doc "Acceptation par le destinataire seulement (idempotente) ; sinon `{:error, :not_found}`."
  def accept(me, request_id) do
    with {:ok, id} <- Ecto.UUID.cast(request_id),
         %Friendship{requester_id: other} <- Repo.get_by(Friendship, id: id, addressee_id: me),
         {:ok, friendship} <- with_pair_lock(me, other, fn -> accept_locked(id) end) do
      notify([me, other])
      MlSocial.Notify.friend_accepted(friendship)
      {:ok, friendship}
    else
      _ -> {:error, :not_found}
    end
  end

  # Relu sous verrou : la demande a pu être refusée, annulée ou supprimée par un blocage entre-temps.
  defp accept_locked(id) do
    case Repo.get(Friendship, id) do
      nil -> {:error, :not_found}
      friendship -> accept_row(friendship)
    end
  end

  defp accept_row(friendship),
    do: friendship |> Ecto.Changeset.change(status: "accepted") |> Repo.update()

  @doc "Refus par le destinataire ou annulation par l'émetteur d'une demande en attente."
  def decline(me, request_id) do
    with {:ok, id} <- Ecto.UUID.cast(request_id),
         %Friendship{status: "pending"} = f <- Repo.get(Friendship, id),
         true <- me in [f.requester_id, f.addressee_id],
         {:ok, _} <- with_pair_lock(f.requester_id, f.addressee_id, fn -> delete_pending(id) end) do
      notify([f.requester_id, f.addressee_id])
      MlSocial.Notify.request_closed(f)
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp delete_pending(id) do
    case Repo.delete_all(from f in Friendship, where: f.id == ^id and f.status == "pending") do
      {1, _} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  @doc "Retire l'amitié avec `user_id` (idempotent)."
  def remove(me, user_id) do
    with {:ok, other} <- cast_path_id(user_id),
         {:ok, {removed, _}} <-
           with_pair_lock(me, other, fn ->
             {:ok, Repo.delete_all(where(pair(me, other), status: "accepted"))}
           end) do
      if removed > 0, do: notify([me, other])
      :ok
    end
  end

  ## Blocages

  @doc "Bloque `user_id` (idempotent) et supprime l'amitié et les demandes entre les deux membres."
  def block(me, user_id) do
    with {:ok, other} <- other_user(me, user_id),
         {:ok, _} <-
           with_pair_lock(me, other, fn ->
             row = %{blocker_id: me, blocked_id: other, inserted_at: DateTime.utc_now()}
             Repo.insert_all(Block, [row], on_conflict: :nothing)
             {:ok, Repo.delete_all(pair(me, other))}
           end) do
      notify([me, other])
      MlSocial.Notify.blocked(me, other)
      :ok
    end
  end

  @doc "Lève le blocage de `user_id` posé par `me` (idempotent)."
  def unblock(me, user_id) do
    with {:ok, other} <- cast_path_id(user_id) do
      {removed, _} =
        Repo.delete_all(from b in Block, where: b.blocker_id == ^me and b.blocked_id == ^other)

      if removed > 0, do: notify([me])
      :ok
    end
  end

  ## Outils partagés avec MlSocial.Chat

  @doc "Exécute `fun` dans une transaction qui verrouille la paire `{a, b}` en mode `:shared` ou `:exclusive`."
  def with_pair_lock(a, b, mode \\ :exclusive, fun) do
    Repo.transact(fn ->
      lock_pair(a, b, mode)
      fun.()
    end)
  end

  @doc "Verrou consultatif de la paire `{a, b}` dans la transaction en cours (`:shared` ou `:exclusive`)."
  def lock_pair(a, b, mode) do
    [low, high] = Enum.sort([a, b])

    lock =
      if mode == :shared, do: "pg_advisory_xact_lock_shared", else: "pg_advisory_xact_lock"

    Repo.query!("SELECT #{lock}(hashtextextended($1, 0))", ["pair:#{low}:#{high}"])
    :ok
  end

  @doc "Identifiant d'un autre membre (corps de requête `user_id`)."
  def other_user(me, user_id) do
    case Ecto.UUID.cast(user_id) do
      {:ok, ^me} -> {:error, :self}
      {:ok, other} -> {:ok, other}
      :error -> {:error, {:invalid, %{user_id: ["is invalid"]}}}
    end
  end

  defp cast_path_id(id) do
    with :error <- Ecto.UUID.cast(id), do: {:error, :not_found}
  end

  defp pair(a, b) do
    from f in Friendship,
      where:
        (f.requester_id == ^a and f.addressee_id == ^b) or
          (f.requester_id == ^b and f.addressee_id == ^a)
  end

  defp notify(ids) do
    for id <- ids, event <- [:friendship_changed, :unread_changed] do
      Events.broadcast(Events.user(id), {event, id})
    end
  end
end
