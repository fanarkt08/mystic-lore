defmodule MlShared.Events do
  @moduledoc """
  Publication et abonnement aux événements de domaine sur le PubSub partagé par le cluster.
  Les messages privés sont livrés membre par membre : un membre retiré d'une conversation ne reçoit plus rien.
  """
  def subscribe(topic), do: Phoenix.PubSub.subscribe(MlShared.PubSub, topic)
  def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(MlShared.PubSub, topic)
  def broadcast(topic, msg), do: Phoenix.PubSub.broadcast(MlShared.PubSub, topic, msg)

  def user(id), do: "user:#{id}"
end
