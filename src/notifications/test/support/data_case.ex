defmodule MlNotifications.DataCase do
  @moduledoc "Tests du domaine avec la sandbox SQL (une transaction annulée par test) et le faux accounts."
  use ExUnit.CaseTemplate

  using do
    quote do
      use Oban.Testing, repo: MlNotifications.Repo
      alias MlNotifications.Repo

      import Ecto.Query
      import MlNotifications.Fixtures
      import MlNotifications.DataCase
    end
  end

  setup tags do
    MlNotifications.DataCase.setup_sandbox(tags)
    MlNotifications.Fixtures.fake_accounts()
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MlNotifications.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
