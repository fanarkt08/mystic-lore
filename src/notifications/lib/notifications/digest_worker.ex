defmodule MlNotifications.DigestWorker do
  @moduledoc "Envoie à la fin des heures calmes un seul résumé des e-mails reportés."
  use Oban.Worker, queue: :email, max_attempts: 8
  import Ecto.Query
  alias MlNotifications.{Emails, PendingEmail, Preferences, QuietHours, Repo}

  @max_items 20

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    setting = Preferences.get(user_id)
    now = DateTime.utc_now()

    if QuietHours.active?(setting, now) do
      {:snooze, max(QuietHours.seconds_left(setting, now), 1)}
    else
      send_digest(user_id, now)
    end
  end

  defp send_digest(user_id, now) do
    {rows, items} = Emails.digest_items(user_id)
    ids = Enum.map(rows, & &1.id)

    result =
      case items do
        [] ->
          :ok

        items ->
          body = %{
            kind: "digest",
            items: Enum.take(items, @max_items),
            total: length(items)
          }

          Emails.request(user_id, body)
      end

    case result do
      :ok ->
        Repo.delete_all(from p in PendingEmail, where: p.id in ^ids)
        if items != [], do: Emails.log_digest!(user_id, now) |> then(&Emails.sent!(&1.id))
        :ok

      {:discard, reason} ->
        Repo.delete_all(from p in PendingEmail, where: p.id in ^ids)
        {:cancel, reason}

      {:retry, reason} ->
        {:error, reason}
    end
  end
end
