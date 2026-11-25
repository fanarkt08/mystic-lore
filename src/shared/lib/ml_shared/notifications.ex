defmodule MlShared.Notifications do
  @moduledoc """
  Envoie les notifications des services au centre de notifications, en un essai ou au mieux.
  Une notification ne transporte jamais de texte ni de contenu privé : seulement `kind` et `params`.
  """
  require Logger
  alias MlShared.Client

  @retry_delays [500, 2_000, 5_000, 15_000, 30_000]

  @doc "Un seul essai : `:ok`, `{:discard, raison}` (refus définitif) ou `{:retry, raison}`."
  def deliver(notification) when is_map(notification) do
    :notifications
    |> Client.post("/api/internal/notifications", json: notification)
    |> outcome()
  end

  @doc "Création avec quelques nouvelles tentatives, à appeler dans `async/1`."
  def notify(notification) when is_map(notification),
    do: with_retries("notification", fn -> deliver(notification) end, delays())

  @doc "Marque lue la notification de `dedupe_key` de `user_id` (ex. conversation lue chez social)."
  def read(user_id, dedupe_key, read_at \\ DateTime.utc_now()) do
    with_retries(
      "read",
      fn ->
        :notifications
        |> Client.post("/api/internal/notifications/read",
          json: %{user_id: user_id, dedupe_key: dedupe_key, read_at: read_at}
        )
        |> outcome()
      end,
      delays()
    )
  end

  @doc "Efface les notifications échangées entre `a` et `b`, dans les deux sens (blocage, chez social)."
  def clear_between(a, b) do
    with_retries(
      "clear",
      fn ->
        :notifications
        |> Client.post("/api/internal/notifications/clear-between", json: %{a: a, b: b})
        |> outcome()
      end,
      delays()
    )
  end

  @doc "Lance `fun` dans une tâche supervisée et renvoie toujours `:ok`, même si la tâche échoue."
  def async(fun) when is_function(fun, 0) do
    if Application.get_env(:ml_shared, :notifications_async, true) do
      case Task.Supervisor.start_child(MlShared.TaskSupervisor, fn -> safely(fun) end) do
        {:ok, _pid} -> :ok
        _error -> Logger.warning("notifications: producer task not started")
      end
    else
      safely(fun)
    end

    :ok
  end

  defp safely(fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.warning("notifications: producer task failed (#{inspect(error.__struct__)})")
      :ok
  catch
    kind, _reason ->
      Logger.warning("notifications: producer task failed (#{kind})")
      :ok
  end

  defp with_retries(what, attempt, delays) do
    case attempt.() do
      :ok ->
        :ok

      {:discard, reason} ->
        Logger.warning("notifications: #{what} refused by the center (#{inspect(reason)})")
        {:error, reason}

      {:retry, reason} when delays == [] ->
        Logger.warning("notifications: #{what} not delivered after retries (#{inspect(reason)})")
        {:error, reason}

      {:retry, _reason} ->
        [delay | rest] = delays
        Process.sleep(delay)
        with_retries(what, attempt, rest)
    end
  end

  defp delays, do: Application.get_env(:ml_shared, :notifications_retry_delays, @retry_delays)

  defp outcome({:ok, _body}), do: :ok

  defp outcome({:error, {:http, status, body}})
       when status in 400..499 and status not in [408, 429],
       do: {:discard, {status, code(body)}}

  defp outcome({:error, {:http, status, _body}}), do: {:retry, {:http, status}}
  defp outcome({:error, :unavailable}), do: {:retry, :unavailable}

  defp code(%{"error" => code}) when is_binary(code), do: code
  defp code(_body), do: nil
end
