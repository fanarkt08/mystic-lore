defmodule MlStudio.DataCase do
  @moduledoc "Tests of the contexts (SQL sandbox, Oban in manual mode, service stubs, fixtures)."
  use ExUnit.CaseTemplate

  using do
    quote do
      use Oban.Testing, repo: MlStudio.Repo
      import Ecto.Query
      import MlStudio.DataCase
      import MlStudio.ServiceStub
      import MlStudio.Fixtures
      alias MlStudio.Repo
    end
  end

  setup tags do
    setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MlStudio.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc "Temporarily changes the studio configuration (restored on exit)."
  def put_studio_env(key, value) do
    previous = Application.fetch_env(:studio, key)
    Application.put_env(:studio, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:studio, key, value)
        :error -> Application.delete_env(:studio, key)
      end
    end)
  end
end
