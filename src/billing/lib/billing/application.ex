defmodule MlBilling.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      MlBilling.Repo,
      {Oban, Application.fetch_env!(:billing, Oban)},
      MlBillingWeb.Endpoint
    ]

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: MlBilling.Supervisor) do
      mode = MlBilling.mode()

      Logger.info(
        "billing payment mode: #{mode}#{if mode == :local, do: " (DEMO, no real payment)"}"
      )

      {:ok, pid}
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    MlBillingWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
