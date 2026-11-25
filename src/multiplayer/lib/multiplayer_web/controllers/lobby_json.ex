defmodule MlMultiplayerWeb.LobbyJSON do
  @moduledoc """
  Formes JSON du contrat multiplayer (clés snake_case, dates ISO 8601 UTC). Les membres sont des « user public »
  d'accounts (`users` : `%{id => user}` obtenu en une requête par réponse).
  """
  alias MlMultiplayer.Link

  @doc "Résumé d'un salon (listes) ; `role` présent dans « mes salons »."
  def summary(%{lobby: lobby, member_count: count} = entry, users) do
    base = %{
      id: lobby.id,
      title: lobby.title,
      visibility: lobby.visibility,
      requires_approval: lobby.requires_approval,
      max_players: lobby.max_players,
      member_count: count,
      status: lobby.status,
      starts_at: lobby.starts_at,
      host: users[lobby.host_id],
      inserted_at: lobby.inserted_at
    }

    if role = entry[:role], do: Map.put(base, :role, role), else: base
  end

  @doc "Vue complète d'un salon pour l'appelant (`MlMultiplayer.Lobbies.detail/2`)."
  def detail(detail, users) do
    %{
      lobby: summary(%{lobby: detail.lobby, member_count: length(detail.members)}, users),
      role: detail.role,
      members:
        for m <- detail.members do
          %{
            user: users[m.user_id],
            host: m.user_id == detail.lobby.host_id,
            ready: m.ready,
            connection: m.connection,
            joined_at: m.joined_at
          }
        end,
      requests:
        for(r <- detail.requests, do: %{user: users[r.user_id], requested_at: r.updated_at}),
      invites:
        for(
          i <- detail.invites,
          do: %{id: i.id, invitee: users[i.invitee_id], inserted_at: i.inserted_at}
        ),
      links: Enum.map(detail.links, &link/1),
      my_invite_id: detail.my_invite && detail.my_invite.id,
      match:
        detail.match &&
          Map.update!(detail.match, "players", &Enum.map(&1, fn id -> users[id] end))
    }
  end

  @doc "Tous les membres à enrichir pour `detail/2`."
  def user_ids(detail) do
    [detail.lobby.host_id] ++
      Enum.map(detail.members, & &1.user_id) ++
      Enum.map(detail.requests, & &1.user_id) ++
      Enum.map(detail.invites, & &1.invitee_id) ++
      if(detail.match, do: detail.match["players"], else: [])
  end

  def link(%Link{} = link) do
    %{
      id: link.id,
      state: Link.state(link),
      max_uses: link.max_uses,
      uses: link.uses,
      expires_at: link.expires_at,
      revoked_at: link.revoked_at,
      inserted_at: link.inserted_at
    }
  end

  def message(message, users) do
    %{
      id: message.id,
      lobby_id: message.lobby_id,
      user_id: message.user_id,
      user: users[message.user_id],
      body: message.body,
      inserted_at: message.inserted_at
    }
  end
end
