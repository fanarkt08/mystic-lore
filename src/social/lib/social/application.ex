defmodule MlSocial.Application do
  @moduledoc false
  use Application

  # Le PubSub (MlShared.PubSub) et la mise en cluster sont démarrés par l'application :ml_shared.
  @impl true
  def start(_type, _args) do
    children = [MlSocial.Repo, MlSocial.Cache, MlSocial.RateLimit, MlSocialWeb.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: MlSocial.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MlSocialWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
