defmodule Mystic.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # The PubSub (MlShared.PubSub) and the Erlang cluster are started by the :ml_shared application;
    # Presence (members online) replicates over it between web nodes.
    children = [Mystic.RateLimiter, MysticWeb.Presence, MysticWeb.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: Mystic.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MysticWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
