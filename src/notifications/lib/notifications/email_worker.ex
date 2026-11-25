defmodule MlNotifications.EmailWorker do
  @moduledoc """
  Demande à accounts l'e-mail d'une notification, sauf si elle a été lue ou le canal coupé entre-temps.
  """
  use Oban.Worker, queue: :email, max_attempts: 8
  alias MlNotifications.{Emails, Notification, Preferences, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, body} <- body(args),
         :ok <- still_wanted(args) do
      case Emails.request(args["user_id"], body) do
        :ok ->
          if is_integer(args["log_id"]), do: Emails.sent!(args["log_id"])
          :ok

        {:discard, reason} ->
          {:cancel, reason}

        {:retry, reason} ->
          {:error, reason}
      end
    end
  end

  # La notification (si elle existe) donne l'état le plus récent : acteur, paramètres, nombre d'événements.
  defp body(%{"notification_id" => id} = args) when is_binary(id) do
    mandatory = args["mandatory"] == true

    case Repo.get(Notification, id) do
      %Notification{read_at: read_at} = n when is_nil(read_at) or mandatory ->
        {:ok, %{kind: n.kind, params: n.params, actor_id: n.actor_id, count: n.count}}

      %Notification{} ->
        {:cancel, "read"}

      nil when mandatory ->
        {:ok, from_args(args)}

      nil ->
        {:cancel, "gone"}
    end
  end

  defp body(args), do: {:ok, from_args(args)}

  defp from_args(args),
    do: %{kind: args["kind"], params: args["params"], actor_id: args["actor_id"], count: 1}

  defp still_wanted(%{"mandatory" => true}), do: :ok

  defp still_wanted(args) do
    setting = Preferences.get(args["user_id"])

    if Preferences.enabled?(setting, args["category"], "email", args["kind"]),
      do: :ok,
      else: {:cancel, "disabled"}
  end
end
