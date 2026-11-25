defmodule MlShared.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # échoue au démarrage plutôt qu'à la première requête si le secret interne manque
    _ = MlShared.InternalToken.secret()

    # le TaskSupervisor porte les envois de notifications « au mieux » (MlShared.Notifications.async/1)
    children = [
      {Phoenix.PubSub, name: MlShared.PubSub},
      MlShared.Cluster,
      {Task.Supervisor, name: MlShared.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MlShared.Supervisor)
  end
end
