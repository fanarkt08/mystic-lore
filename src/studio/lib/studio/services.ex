defmodule MlStudio.Services do
  @moduledoc """
  Calls to the other services. An unreachable service makes the action fail: no role, plan or credit is ever
  assumed.
  """
  alias MlShared.Client

  @doc "accounts: public member by username."
  def user_by_username(username) do
    case Client.get(:accounts, "/api/users/by-username/:username",
           path_params: [username: username]
         ) do
      {:ok, %{"user" => %{"id" => _} = user}} -> {:ok, user}
      {:error, {:http, 404, _}} -> {:error, :user_not_found}
      _ -> {:error, :unavailable}
    end
  end

  @doc "accounts: is the member a moderator or an admin?"
  def staff?(user_id) do
    case Client.get(:accounts, "/api/internal/users/:id", path_params: [id: user_id]) do
      {:ok, %{"user" => %{"role" => role}}} -> {:ok, role in ["moderator", "admin"]}
      {:error, {:http, 404, _}} -> {:ok, false}
      _ -> {:error, :unavailable}
    end
  end

  @doc """
  accounts: central audit entry of a staff action (`studio.…`), written inside the action's transaction:
  `{:error, :audit_unavailable}` cancels the action.
  """
  def audit(actor_id, action, target_id, reason, metadata) do
    case Client.post(:accounts, "/api/internal/audit",
           json: %{
             actor_id: actor_id,
             action: action,
             target_type: "project",
             target_id: target_id,
             reason: reason,
             metadata: metadata
           }
         ) do
      {:ok, %{"id" => _}} -> :ok
      _ -> {:error, :audit_unavailable}
    end
  end

  @doc "social: is there a block between the two members (either way)?"
  def blocked?(a, b) do
    case Client.get(:social, "/api/internal/relationship", params: [a: a, b: b]) do
      {:ok, %{"blocked" => blocked}} when is_boolean(blocked) -> {:ok, blocked}
      _ -> {:error, :unavailable}
    end
  end

  @doc "billing: effective plan of the member."
  def plan(user_id) do
    case Client.get(:billing, "/api/entitlements/:id", path_params: [id: user_id]) do
      {:ok, %{"plan" => plan}} when is_binary(plan) -> {:ok, plan}
      _ -> {:error, :unavailable}
    end
  end

  @doc "billing: holds `amount` credits under `ref` (402 → `{:error, {:insufficient_credits, balance}}`)."
  def reserve(user_id, amount, ref, reason) do
    case Client.post(:billing, "/api/internal/credits/reserve",
           json: %{user_id: user_id, amount: amount, ref: ref, reason: reason}
         ) do
      {:ok, %{"status" => "held"} = body} ->
        {:ok, body}

      {:error, {:http, 402, %{"balance" => balance}}} ->
        {:error, {:insufficient_credits, balance}}

      {:ok, _other_state} ->
        {:error, :reservation_closed}

      _ ->
        {:error, :credits_unavailable}
    end
  end

  @doc "billing: ends a reservation, `:consume` (success) or `:release` (refund)."
  def settle(user_id, ref, operation) when operation in [:consume, :release] do
    Client.post(:billing, "/api/internal/credits/#{operation}",
      json: %{user_id: user_id, ref: ref}
    )
  end

  @doc "learning: imports an approved version."
  def import_adventure(payload),
    do: Client.post(:learning, "/api/internal/adventures/import", json: payload)
end
