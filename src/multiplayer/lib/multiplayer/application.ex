defmodule MlMultiplayer.Application do
  @moduledoc false
  use Application

  # Un MatchServer par partie en cours, sous un Registry et un DynamicSupervisor ; le PubSub vient de :ml_shared.
  @impl true
  def start(_type, _args) do
    children = [
      MlMultiplayer.Repo,
      MlMultiplayer.Cache,
      {Registry, keys: :unique, name: MlMultiplayer.MatchRegistry},
      {DynamicSupervisor, name: MlMultiplayer.MatchSupervisor, strategy: :one_for_one},
      MlMultiplayer.Sweeper,
      MlMultiplayerWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MlMultiplayer.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MlMultiplayerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
