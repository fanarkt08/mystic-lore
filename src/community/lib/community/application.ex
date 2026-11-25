defmodule MlCommunity.Application do
  @moduledoc false
  use Application

  # Le PubSub (MlShared.PubSub) et la mise en cluster sont démarrés par l'application :ml_shared.
  @impl true
  def start(_type, _args) do
    children = [MlCommunity.Repo, MlCommunity.Cache, MlCommunityWeb.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: MlCommunity.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MlCommunityWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
