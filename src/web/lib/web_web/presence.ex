defmodule MysticWeb.Presence do
  @moduledoc """
  Statut « en ligne » des membres, montré seulement aux amis qui l'autorisent et jamais utilisé pour un accès.
  """
  use Phoenix.Presence, otp_app: :web, pubsub_server: MlShared.PubSub

  @topic "members:online"

  def track_member(pid, user_id), do: track(pid, @topic, user_id, %{})

  def subscribe, do: Phoenix.PubSub.subscribe(MlShared.PubSub, @topic)

  def online_ids, do: @topic |> list() |> Map.keys() |> MapSet.new()

  @doc "Amis à montrer « en ligne » : ceux qui l'autorisent et qui sont connectés."
  def visible(friends, online) when is_list(friends) do
    for f <- friends,
        f["online_visible"] == true,
        MapSet.member?(online, f["id"]),
        into: MapSet.new(),
        do: f["id"]
  end

  def visible(_friends, _online), do: MapSet.new()
end
