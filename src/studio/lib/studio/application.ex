defmodule MlStudio.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      MlStudio.Repo,
      {Oban, Application.fetch_env!(:studio, Oban)},
      MlStudioWeb.Endpoint
    ]

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: MlStudio.Supervisor) do
      provider = MlStudio.AI.provider()

      Logger.info(
        "studio AI provider: #{provider.name()}" <>
          cond do
            provider == MlStudio.AI.Deterministic -> " (DEMO MODE — not a real AI)"
            provider.configured?() -> " (model #{provider.model()})"
            true -> " (NOT CONFIGURED: ANTHROPIC_API_KEY is missing, generations are refused)"
          end
      )

      {:ok, pid}
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    MlStudioWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
