defmodule MlAccounts.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MlAccounts.Repo,
      {Oban, Application.fetch_env!(:accounts, Oban)},
      MlAccountsWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MlAccounts.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    MlAccountsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
