defmodule MlLearning.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [MlLearning.Repo, MlLearning.Entitlements, MlLearningWeb.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: MlLearning.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MlLearningWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
