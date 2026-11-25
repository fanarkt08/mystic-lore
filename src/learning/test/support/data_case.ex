defmodule MlLearning.DataCase do
  @moduledoc "Tests de contextes dans le bac à sable SQL (annulé à la fin de chaque test)."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias MlLearning.Repo
      import Ecto.Query
      import MlLearning.DataCase
      import MlLearning.Fixtures
    end
  end

  setup tags do
    MlLearning.DataCase.setup_sandbox(tags)
    MlLearning.Fixtures.stub_center()
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MlLearning.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
