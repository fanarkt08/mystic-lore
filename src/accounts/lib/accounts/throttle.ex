defmodule MlAccounts.Throttle do
  @moduledoc """
  Limites à fenêtre glissante stockées en base et partagées entre nœuds.
  La tentative est réservée avant la vérification, sous verrou, pour ne jamais dépasser la limite.
  """
  use Ecto.Schema
  import Ecto.Query
  alias MlAccounts.Repo

  schema "throttle_events" do
    field :key, :string
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "`:ok` (tentative enregistrée), ou `{:error, :locked}` si `key` compte déjà `limit` tentatives sur `minutes`."
  def reserve(key, limit, minutes), do: reserve(__MODULE__, :key, key, limit, minutes)

  @doc "Même règle sur une autre table d'événements (verrouillage des connexions : `LoginFailure`, champ `email`)."
  def reserve(schema, field, key, limit, minutes) do
    Repo.transact(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [key])
      events = from e in schema, where: field(e, ^field) == ^key
      Repo.delete_all(where(events, [e], e.inserted_at <= ago(^minutes, "minute")))

      if Repo.aggregate(events, :count) >= limit,
        do: {:error, :locked},
        else: {:ok, Repo.insert!(struct(schema, [{field, key}]))}
    end)
    |> case do
      {:ok, _event} -> :ok
      error -> error
    end
  end

  def clear(key) do
    Repo.delete_all(from e in __MODULE__, where: e.key == ^key)
    :ok
  end
end
