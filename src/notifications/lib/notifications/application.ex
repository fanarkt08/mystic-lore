defmodule MlNotifications.Application do
  @moduledoc false
  use Application

  # Le PubSub (MlShared.PubSub) et la mise en cluster sont démarrés par l'application :ml_shared.
  @impl true
  def start(_type, _args) do
    children = [
      MlNotifications.Repo,
      {Oban, Application.fetch_env!(:notifications, Oban)},
      MlNotificationsWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MlNotifications.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MlNotificationsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
