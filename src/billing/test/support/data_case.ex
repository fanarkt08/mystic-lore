defmodule MlBilling.DataCase do
  @moduledoc "Tests of the data layer (SQL sandbox, helpers of `MlBilling.TestHelpers`)."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias MlBilling.Repo
      import Ecto.Query
      import MlBilling.DataCase
      import MlBilling.TestHelpers
    end
  end

  setup tags do
    MlBilling.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MlBilling.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
