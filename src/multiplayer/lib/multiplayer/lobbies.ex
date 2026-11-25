defmodule MlMultiplayer.Lobbies do
  @moduledoc """
  Salons : listes, création, admission, partie, départs et exclusion. Le rôle de l'appelant est recalculé
  depuis la base à chaque appel, et une admission ne dépasse jamais `max_players`, même en concurrence.
  """
  import Ecto.Query
  alias MlMultiplayer.{Invite, Link, Lobby, Matches, MatchServer, Member, Presence, Repo, Social}
  alias MlShared.Events

  @max_hosted 3
  @page_size 20
  @members ~w(host player)a

  def topic(lobby_id), do: "lobby:#{lobby_id}"
  def changed(lobby_id), do: Events.broadcast(topic(lobby_id), {:lobby_changed, lobby_id})

  ## Accès et rôles

  @doc "`{:ok, lobby, role}`, `{:error, :not_found}` ou `{:error, :banned}`."
  def fetch(user_id, lobby_id) do
    with {:ok, id} <- MlMultiplayer.cast_uuid(lobby_id),
         %Lobby{status: status} = lobby when status != "closed" <- Repo.get(Lobby, id) do
      case role(lobby, user_id) do
        :banned -> {:error, :banned}
        nil -> {:error, :not_found}
        role -> {:ok, lobby, role}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Comme `fetch/2`, en exigeant l'un des rôles `roles` (sinon `{:error, :forbidden}`)."
  def authorize(user_id, lobby_id, roles) do
    with {:ok, lobby, role} <- fetch(user_id, lobby_id) do
      if role in roles, do: {:ok, lobby, role}, else: {:error, :forbidden}
    end
  end

  defp role(lobby, user_id) do
    case Repo.get_by(Member, lobby_id: lobby.id, user_id: user_id) do
      %Member{status: "active"} ->
        if lobby.host_id == user_id, do: :host, else: :player

      %Member{status: "pending"} ->
        :pending

      %Member{status: "kicked"} ->
        :banned

      _ ->
        cond do
          pending_invite(lobby.id, user_id) -> :invited
          lobby.visibility == "open" -> :spectator
          true -> nil
        end
    end
  end

  defp pending_invite(lobby_id, user_id),
    do: Repo.get_by(Invite, lobby_id: lobby_id, invitee_id: user_id, status: "pending")

  @doc "Membres actifs, du plus ancien au plus récent (ordre de transfert d'hôte)."
  def active_ids(lobby_id) do
    Repo.all(
      from m in Member,
        where: m.lobby_id == ^lobby_id and m.status == "active",
        order_by: [m.joined_at, m.user_id],
        select: m.user_id
    )
  end

  @doc "Nombre de membres actifs par salon."
  def counts(lobby_ids) do
    Repo.all(
      from m in Member,
        where: m.lobby_id in ^lobby_ids and m.status == "active",
        group_by: m.lobby_id,
        select: {m.lobby_id, count()}
    )
    |> Map.new()
  end

  @doc "Identifiant d'un autre membre passé dans le corps de la requête."
  def other(me, user_id) do
    case MlMultiplayer.cast_uuid(user_id) do
      {:ok, ^me} -> {:error, {:invalid, %{user_id: ["cannot be yourself"]}}}
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:invalid, %{user_id: ["is invalid"]}}}
    end
  end

  ## Listes

  @doc """
  Salons ouverts que `user_id` peut rejoindre (20 par page, les plus récents d'abord) : hors ceux dont il est
  membre, demandeur ou exclu, et hors ceux d'un hôte avec qui il a un blocage.
  """
  def list_open(user_id, page) do
    with {:ok, blocked} <- Social.blocked_ids(user_id) do
      mine =
        from m in Member,
          where: m.user_id == ^user_id and m.status in ["active", "pending", "kicked"],
          select: m.lobby_id

      query =
        from l in Lobby,
          where: l.visibility == "open" and l.status != "closed",
          where: l.host_id not in ^blocked and l.id not in subquery(mine)

      total = Repo.aggregate(query, :count)

      lobbies =
        query
        |> order_by([l], desc: l.inserted_at, desc: l.id)
        |> limit(@page_size)
        |> offset(^((page - 1) * @page_size))
        |> Repo.all()

      {:ok,
       %{
         entries: with_counts(lobbies),
         page: page,
         total_pages: max(div(total + @page_size - 1, @page_size), 1),
         total: total
       }}
    end
  end

  @doc "Salons (non fermés) dont `user_id` est membre ou demandeur, avec son rôle."
  def list_mine(user_id) do
    rows =
      Repo.all(
        from l in Lobby,
          join: m in Member,
          on: m.lobby_id == l.id and m.user_id == ^user_id and m.status in ["active", "pending"],
          where: l.status != "closed",
          order_by: [desc: l.updated_at, desc: l.id],
          select: {l, m.status}
      )

    counts = counts(Enum.map(rows, &elem(&1, 0).id))

    for {lobby, status} <- rows do
      role =
        cond do
          status == "pending" -> :pending
          lobby.host_id == user_id -> :host
          true -> :player
        end

      %{lobby: lobby, member_count: Map.get(counts, lobby.id, 0), role: role}
    end
  end

  defp with_counts(lobbies) do
    counts = counts(Enum.map(lobbies, & &1.id))
    Enum.map(lobbies, &%{lobby: &1, member_count: Map.get(counts, &1.id, 0)})
  end

  @doc "Tout ce que l'appelant peut voir d'un salon (outils de l'hôte compris s'il l'est)."
  def detail(user_id, lobby_id) do
    with {:ok, lobby, role} <- fetch(user_id, lobby_id) do
      host? = role == :host

      members =
        Repo.all(
          from m in Member,
            where: m.lobby_id == ^lobby.id and m.status == "active",
            order_by: [m.joined_at, m.user_id]
        )

      {:ok,
       %{
         lobby: lobby,
         role: role,
         members: members,
         requests: if(host?, do: requests(lobby.id), else: []),
         invites: if(host?, do: invites(lobby.id), else: []),
         links: if(host?, do: links(lobby.id), else: []),
         my_invite: if(role == :invited, do: pending_invite(lobby.id, user_id)),
         match: Matches.view(lobby, user_id)
       }}
    end
  end

  defp requests(lobby_id),
    do:
      Repo.all(
        from m in Member,
          where: m.lobby_id == ^lobby_id and m.status == "pending",
          order_by: m.updated_at
      )

  defp invites(lobby_id),
    do:
      Repo.all(
        from i in Invite,
          where: i.lobby_id == ^lobby_id and i.status == "pending",
          order_by: [desc: i.updated_at]
      )

  defp links(lobby_id),
    do:
      Repo.all(
        from l in Link,
          where: l.lobby_id == ^lobby_id,
          order_by: [desc: l.inserted_at],
          limit: 10
      )

  ## Création

  @doc "Crée un salon dont `user_id` est l'hôte, 3 salons ouverts au plus par hôte."
  def create(user_id, attrs) do
    changeset = Lobby.create_changeset(%Lobby{host_id: user_id, status: "waiting"}, attrs)

    Repo.transact(fn ->
      # sérialise les créations d'un même hôte : la limite tient en concurrence
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["host:#{user_id}"])

      hosted =
        Repo.aggregate(
          from(l in Lobby, where: l.host_id == ^user_id and l.status != "closed"),
          :count
        )

      with :ok <- if(hosted >= @max_hosted, do: {:error, :too_many_lobbies}, else: :ok),
           {:ok, lobby} <- Repo.insert(changeset) do
        put_member!(lobby.id, user_id, "active")
        {:ok, lobby}
      end
    end)
  end

  ## Admission

  @doc "Rejoint un salon visible, ou envoie une demande si l'hôte approuve les arrivées."
  def join(user_id, lobby_id) do
    with {:ok, lobby, role} <- fetch(user_id, lobby_id) do
      case role do
        role when role in @members ->
          {:ok, :joined}

        :pending ->
          {:ok, :pending}

        role ->
          with {:ok, blocked} <- Social.blocked_ids(user_id) do
            admit(lobby.id, user_id, if(role == :invited, do: :direct, else: :open), blocked)
          end
      end
    end
  end

  @doc "Admet un membre dans sa propre transaction, puis diffuse le changement."
  def admit(lobby_id, user_id, mode, blocked) do
    with {:ok, outcome} <-
           Repo.transact(fn -> admit_locked(lobby_id, user_id, mode, blocked) end) do
      changed(lobby_id)
      {:ok, outcome}
    end
  end

  @doc "Cœur de l'admission, à appeler dans une transaction : verrou du salon, puis règles et capacité."
  def admit_locked(lobby_id, user_id, mode, blocked) do
    lobby = Repo.one(from l in Lobby, where: l.id == ^lobby_id, lock: "FOR UPDATE")
    member = Repo.get_by(Member, lobby_id: lobby_id, user_id: user_id)
    active = active_ids(lobby_id)

    cond do
      is_nil(lobby) -> {:error, :not_found}
      lobby.status == "closed" -> {:error, :closed}
      match?(%Member{status: "kicked"}, member) -> {:error, :banned}
      match?(%Member{status: "active"}, member) -> {:ok, :joined}
      mode == :approve and not match?(%Member{status: "pending"}, member) -> {:error, :not_found}
      Enum.any?(active, &(&1 in blocked)) -> {:error, :blocked}
      mode == :open and lobby.requires_approval -> put_member(lobby_id, user_id, "pending")
      length(active) >= lobby.max_players -> {:error, :full}
      true -> put_member(lobby_id, user_id, "active")
    end
  end

  defp put_member(lobby_id, user_id, "pending") do
    put_member!(lobby_id, user_id, "pending")
    {:ok, :pending}
  end

  defp put_member(lobby_id, user_id, "active") do
    put_member!(lobby_id, user_id, "active")

    Repo.update_all(
      from(i in Invite,
        where: i.lobby_id == ^lobby_id and i.invitee_id == ^user_id and i.status == "pending"
      ),
      set: [status: "accepted", updated_at: DateTime.utc_now()]
    )

    {:ok, :joined}
  end

  defp put_member!(lobby_id, user_id, status) do
    now = DateTime.utc_now()

    Repo.insert!(
      %Member{
        lobby_id: lobby_id,
        user_id: user_id,
        status: status,
        ready: false,
        connection: "online",
        last_seen_at: now,
        joined_at: now
      },
      on_conflict:
        {:replace, [:status, :ready, :connection, :last_seen_at, :joined_at, :updated_at]},
      conflict_target: [:lobby_id, :user_id]
    )
  end

  @doc "L'hôte accepte une demande en attente (capacité et blocages revérifiés)."
  def approve(host_id, lobby_id, user_id) do
    with {:ok, lobby, _} <- authorize(host_id, lobby_id, [:host]),
         {:ok, target} <- path_user(user_id),
         {:ok, blocked} <- Social.blocked_ids(target),
         {:ok, :joined} <- admit(lobby.id, target, :approve, blocked),
         do: :ok
  end

  @doc "L'hôte refuse une demande en attente."
  def decline(host_id, lobby_id, user_id) do
    with {:ok, lobby, _} <- authorize(host_id, lobby_id, [:host]),
         {:ok, target} <- path_user(user_id) do
      case Repo.update_all(
             from(m in Member,
               where: m.lobby_id == ^lobby.id and m.user_id == ^target and m.status == "pending"
             ),
             set: [status: "declined", updated_at: DateTime.utc_now()]
           ) do
        {1, _} ->
          changed(lobby.id)
          :ok

        _ ->
          {:error, :not_found}
      end
    end
  end

  defp path_user(user_id) do
    with :error <- MlMultiplayer.cast_uuid(user_id), do: {:error, :not_found}
  end

  ## Salle d'attente et partie

  @doc "Se déclarer prêt (ou non) : membres actifs, salon en attente."
  def set_ready(user_id, lobby_id, ready) when is_boolean(ready) do
    with {:ok, lobby, _} <- authorize(user_id, lobby_id, @members) do
      if lobby.status == "waiting" do
        Repo.update_all(
          from(m in Member,
            where: m.lobby_id == ^lobby.id and m.user_id == ^user_id and m.status == "active"
          ),
          set: [ready: ready, updated_at: DateTime.utc_now()]
        )

        changed(lobby.id)
        :ok
      else
        {:error, :in_progress}
      end
    end
  end

  @doc "Lance la partie avec au moins 2 membres prêts et présents, jamais avant `starts_at`."
  def start(host_id, lobby_id, now \\ DateTime.utc_now()) do
    with {:ok, lobby, _} <- authorize(host_id, lobby_id, [:host]),
         {:ok, match} <- Repo.transact(fn -> start_locked(lobby.id, host_id, now) end) do
      changed(lobby.id)
      {:ok, match}
    end
  end

  defp start_locked(lobby_id, host_id, now) do
    lobby = Repo.one!(from l in Lobby, where: l.id == ^lobby_id, lock: "FOR UPDATE")

    ready =
      Repo.all(
        from m in Member,
          where: m.lobby_id == ^lobby_id and m.status == "active" and m.ready,
          where: m.connection != "absent",
          order_by: [m.joined_at, m.user_id],
          select: m.user_id
      )

    cond do
      lobby.host_id != host_id ->
        {:error, :forbidden}

      lobby.status != "waiting" ->
        {:error, :in_progress}

      Lobby.scheduled_later?(lobby, now) ->
        {:error, :not_yet}

      length(ready) < 2 ->
        {:error, :not_enough_ready}

      true ->
        seed = :crypto.strong_rand_bytes(6) |> :binary.decode_unsigned()
        match = Matches.create!(lobby, ready, seed)

        Repo.update_all(from(l in Lobby, where: l.id == ^lobby_id),
          set: [status: "playing", current_match_id: match.id, updated_at: now]
        )

        {:ok, match}
    end
  end

  @doc "Intention d'un joueur pendant la partie : proposer une séquence (validée par le MatchServer)."
  def attempt(user_id, lobby_id, sequence) do
    with {:ok, lobby, _} <- authorize(user_id, lobby_id, @members) do
      case lobby do
        %Lobby{status: "playing", current_match_id: id} when is_binary(id) ->
          with :ok <- MatchServer.propose(id, user_id, sequence),
               do: {:ok, Matches.view(lobby, user_id)}

        _ ->
          {:error, :no_match}
      end
    end
  end

  ## Départs, hôte, exclusion

  @doc "Fait quitter le salon ; l'hôte qui part est remplacé et le dernier départ ferme le salon."
  def leave(user_id, lobby_id) do
    with {:ok, lobby, role} <- fetch(user_id, lobby_id) do
      if role in [:host, :player, :pending],
        do: remove(lobby.id, user_id, "left"),
        else: {:error, :forbidden}
    end
  end

  @doc "L'hôte exclut un membre (ou un demandeur) : il ne pourra plus rejoindre ce salon."
  def kick(host_id, lobby_id, user_id) do
    with {:ok, lobby, _} <- authorize(host_id, lobby_id, [:host]),
         {:ok, target} <- other(host_id, user_id),
         do: remove(lobby.id, target, "kicked")
  end

  defp remove(lobby_id, user_id, status) do
    result =
      Repo.transact(fn ->
        lobby = Repo.one!(from l in Lobby, where: l.id == ^lobby_id, lock: "FOR UPDATE")
        now = DateTime.utc_now()

        case Repo.get_by(Member, lobby_id: lobby_id, user_id: user_id) do
          %Member{status: current} when current in ["active", "pending"] ->
            Repo.update_all(
              from(m in Member, where: m.lobby_id == ^lobby_id and m.user_id == ^user_id),
              set: [status: status, ready: false, updated_at: now]
            )

            revoke_invites(from(i in Invite, where: i.invitee_id == ^user_id), lobby_id, now)

            case active_ids(lobby_id) do
              [] -> close!(lobby_id, now)
              [next | _] when lobby.host_id == user_id -> set_lobby!(lobby_id, host_id: next)
              _ -> :ok
            end

            {:ok, lobby}

          _ ->
            {:error, :not_found}
        end
      end)

    with {:ok, lobby} <- result do
      # partie en cours : le joueur parti est sauté, ou la partie est interrompue s'il en reste moins de 2
      if lobby.status == "playing", do: Presence.reconcile(lobby_id)
      changed(lobby_id)
      :ok
    end
  end

  defp close!(lobby_id, now) do
    set_lobby!(lobby_id, status: "closed")

    Repo.update_all(
      from(m in Member, where: m.lobby_id == ^lobby_id and m.status == "pending"),
      set: [status: "declined", updated_at: now]
    )

    revoke_invites(Invite, lobby_id, now)
  end

  defp revoke_invites(query, lobby_id, now) do
    Repo.update_all(
      from(i in query, where: i.lobby_id == ^lobby_id and i.status == "pending"),
      set: [status: "revoked", updated_at: now]
    )
  end

  defp set_lobby!(lobby_id, changes) do
    Repo.update_all(from(l in Lobby, where: l.id == ^lobby_id),
      set: changes ++ [updated_at: DateTime.utc_now()]
    )
  end

  @doc "L'hôte cède son rôle à un autre membre actif."
  def transfer(host_id, lobby_id, user_id) do
    with {:ok, lobby, _} <- authorize(host_id, lobby_id, [:host]),
         {:ok, target} <- other(host_id, user_id),
         {:ok, _} <-
           Repo.transact(fn ->
             locked = Repo.one!(from l in Lobby, where: l.id == ^lobby.id, lock: "FOR UPDATE")

             cond do
               locked.host_id != host_id -> {:error, :forbidden}
               target not in active_ids(lobby.id) -> {:error, :not_found}
               true -> {:ok, set_lobby!(lobby.id, host_id: target)}
             end
           end) do
      changed(lobby.id)
      :ok
    end
  end

  ## Signalement

  @doc "Signale un joueur de ce salon au service social (motif et détails validés par social)."
  def report(user_id, lobby_id, params) do
    with {:ok, lobby, _} <- authorize(user_id, lobby_id, @members),
         {:ok, target} <- other(user_id, params["user_id"]),
         %Member{} <-
           Repo.get_by(Member, lobby_id: lobby.id, user_id: target) || {:error, :not_found} do
      details =
        case params["details"] do
          text when is_binary(text) and text != "" -> String.slice(text, 0, 1500)
          _ -> nil
        end

      context = "Multiplayer lobby #{lobby.id}"

      Social.report(
        user_id,
        target,
        params["reason"],
        Enum.join([context | List.wrap(details)], ": ")
      )
    end
  end
end
