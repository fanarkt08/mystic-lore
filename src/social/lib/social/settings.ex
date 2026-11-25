defmodule MlSocial.Settings do
  @moduledoc """
  Réglages de confidentialité et permissions de contact, décidées ici pour tous les services.
  Un refus ne donne que son code, sans révéler le réglage ni les amis communs.
  """
  import Ecto.Query
  alias MlShared.Events
  alias MlSocial.{Delivery, Friends, Repo, Setting}

  @kinds ~w(friend_request group_add lobby_invite)

  def kinds, do: @kinds

  @doc "Réglages de `user_id` (valeurs par défaut s'il n'en a jamais enregistré)."
  def get(user_id), do: Repo.get(Setting, user_id) || %Setting{user_id: user_id}

  @doc "`%{id => %Setting{}}` pour chaque id (une requête)."
  def for_users(ids) do
    found = Repo.all(from s in Setting, where: s.user_id in ^ids) |> Map.new(&{&1.user_id, &1})
    Map.new(ids, &{&1, Map.get(found, &1, %Setting{user_id: &1})})
  end

  @doc "Changement partiel, sérialisé par membre : `{:ok, setting}` ou `{:error, changeset}`."
  def update(me, attrs) do
    result =
      Repo.transact(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["settings:#{me}"])
        before = get(me)

        with {:ok, setting} <- before |> Setting.changeset(attrs) |> Repo.insert_or_update() do
          {:ok, {before, setting}}
        end
      end)

    with {:ok, {before, setting}} <- result do
      notify(me, before, setting)
      {:ok, setting}
    end
  end

  defp notify(me, before, setting) do
    Events.broadcast(Events.user(me), {:social_settings_changed, me})

    if before.show_online != setting.show_online do
      for friend <- Friends.friend_ids(me),
          do: Events.broadcast(Events.user(friend), {:friendship_changed, friend})
    end

    if before.read_receipts != setting.read_receipts, do: Delivery.conversations_changed(me)
  end

  @doc "`:ok` ou `{:error, code}` : `from` peut-il contacter `to` de cette façon ?"
  def can_contact(from, to, kind) when kind in @kinds do
    cond do
      from == to -> {:error, :self}
      Friends.blocked?(from, to) -> {:error, :blocked}
      true -> permission(from, to, kind)
    end
  end

  @doc "Permission seule (le blocage est vérifié par l'appelant, sous son verrou)."
  def permission(from, to, "friend_request") do
    case get(to).friend_requests do
      "everyone" -> :ok
      "friends_of_friends" -> if mutual_friend?(from, to), do: :ok, else: closed("friend_request")
      "nobody" -> closed("friend_request")
    end
  end

  def permission(from, to, kind) do
    setting = get(to)

    cond do
      not Friends.friends?(from, to) -> {:error, :not_friends}
      Map.fetch!(setting, field(kind)) == "friends" -> :ok
      true -> closed(kind)
    end
  end

  defp field("group_add"), do: :group_adds
  defp field("lobby_invite"), do: :lobby_invites

  defp closed("friend_request"), do: {:error, :friend_requests_closed}
  defp closed("group_add"), do: {:error, :group_adds_closed}
  defp closed("lobby_invite"), do: {:error, :lobby_invites_closed}

  defp mutual_friend?(a, b) do
    not MapSet.disjoint?(MapSet.new(Friends.friend_ids(a)), MapSet.new(Friends.friend_ids(b)))
  end
end
