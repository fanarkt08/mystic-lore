defmodule MlSocial.DataCase do
  @moduledoc "Tests du domaine avec la sandbox SQL (une transaction annulée par test)."
  use ExUnit.CaseTemplate

  using do
    quote do
      alias MlSocial.Repo

      import Ecto.Query
      import MlSocial.Fixtures
      import MlSocial.DataCase
    end
  end

  setup tags do
    MlSocial.DataCase.setup_sandbox(tags)
    Req.Test.stub(MlShared.Client, &MlSocialWeb.ConnCase.fake_accounts/1)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MlSocial.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
