defmodule MlMultiplayer.DataCase do
  @moduledoc """
  Tests du domaine dans la sandbox SQL, avec de faux accounts, social et learning.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias MlMultiplayer.Repo

      import Ecto.Query
      import MlMultiplayer.Fixtures
      import MlMultiplayer.DataCase
    end
  end

  setup tags do
    MlMultiplayer.DataCase.setup_sandbox(tags)
    MlMultiplayer.Fixtures.stub_services()
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MlMultiplayer.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc "Erreurs d'un changeset sous forme `%{champ: [message]}`."
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
