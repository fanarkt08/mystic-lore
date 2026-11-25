defmodule MlAccounts.DataCase do
  @moduledoc "Tests de la couche données, dans le bac à sable SQL (annulé à la fin de chaque test)."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias MlAccounts.Repo
      import MlAccounts.DataCase
      import MlAccounts.Fixtures
    end
  end

  setup tags do
    MlAccounts.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MlAccounts.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
