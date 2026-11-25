defmodule MlCommunity.DataCase do
  @moduledoc "Tests du domaine avec la sandbox SQL (une transaction annulée par test) et de faux services."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias MlCommunity.Repo

      import Ecto.Query
      import MlCommunity.Fixtures
      import MlCommunity.DataCase
    end
  end

  setup tags do
    MlCommunity.DataCase.setup_sandbox(tags)
    MlCommunity.Fixtures.stub_services()
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MlCommunity.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
