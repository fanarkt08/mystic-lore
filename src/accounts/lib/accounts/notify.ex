defmodule MlAccounts.Notify do
  @moduledoc """
  Met en file les notifications des catégories `security` et `account`, sans jamais faire échouer l'action.
  """
  require Logger
  alias MlAccounts.NotifyWorker

  @doc "Événement de sécurité du membre (`password_changed`, `two_factor_enabled`…)."
  def security(user_id, kind, params \\ %{}),
    do: enqueue(user_id, "security", kind, params, "security:#{kind}:#{Ecto.UUID.generate()}")

  @doc "Événement du compte (sanction, appel, export) ; `key` identifie l'événement (idempotence)."
  def account(user_id, kind, params, key), do: enqueue(user_id, "account", kind, params, key)

  defp enqueue(user_id, category, kind, params, key) do
    %{user_id: user_id, category: category, kind: kind, params: params, dedupe_key: key}
    |> NotifyWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, _changeset} -> Logger.error("notification #{kind} not queued for user #{user_id}")
    end

    :ok
  rescue
    error ->
      Logger.error(
        "notification #{kind} not queued for user #{user_id} (#{inspect(error.__struct__)})"
      )

      :ok
  end
end
