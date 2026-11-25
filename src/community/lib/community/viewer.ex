defmodule MlCommunity.Viewer do
  @moduledoc """
  Lecteur d'une requête, résolu à partir du seul `user_id` du jeton interne.
  Si social est injoignable, un membre ne reçoit aucun contenu, car les blocages ne seraient plus garantis.
  """
  alias MlCommunity.{Accounts, Social}

  defstruct id: nil, staff: false, blocked: [], restricted_until: nil

  def resolve(nil), do: {:ok, %__MODULE__{}}

  def resolve(id) do
    case Social.blocked_ids(id) do
      {:ok, blocked} ->
        {staff, restricted_until} =
          case Accounts.member(id) do
            {:ok, member} -> {member.role in ~w(moderator admin), member.restricted_until}
            {:error, :unavailable} -> {false, :unknown}
          end

        {:ok,
         %__MODULE__{id: id, staff: staff, blocked: blocked, restricted_until: restricted_until}}

      {:error, :unavailable} ->
        {:error, :blocks_unavailable}
    end
  end

  @doc """
  Publier (discussion, réponse, édition) : refusé à un membre restreint par le staff (`{:restricted, fin}`), et par
  prudence si accounts n'a pas pu confirmer l'absence de restriction (`:roles_unavailable`).
  """
  def can_publish(%__MODULE__{restricted_until: :unknown}), do: {:error, :roles_unavailable}

  def can_publish(%__MODULE__{restricted_until: %DateTime{} = until}) do
    if DateTime.after?(until, DateTime.utc_now()),
      do: {:error, {:restricted, until}},
      else: :ok
  end

  def can_publish(%__MODULE__{}), do: :ok

  @doc "Droits de lecture du staff : seulement si accounts confirme le rôle."
  def staff?(nil), do: false
  def staff?(id), do: Accounts.staff?(id) == {:ok, true}

  @doc "Actions de modération : `:ok`, `{:error, :forbidden}` ou `{:error, :roles_unavailable}` (accounts injoignable)."
  def require_staff(id) do
    case Accounts.staff?(id) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :forbidden}
      {:error, :unavailable} -> {:error, :roles_unavailable}
    end
  end
end
