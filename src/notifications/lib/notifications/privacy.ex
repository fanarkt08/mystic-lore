defmodule MlNotifications.Privacy do
  @moduledoc """
  Export et suppression des données d'un membre dans le centre, appelés par accounts seulement.
  """
  import Ecto.Query
  alias MlNotifications.{EmailLog, Notification, PendingEmail, Preferences, Repo, Setting}

  def export(user_id) do
    notifications =
      Repo.all(
        from n in Notification,
          where: n.user_id == ^user_id,
          order_by: [desc: n.last_event_at, desc: n.id]
      )

    setting = Preferences.get(user_id)

    %{
      "notifications" =>
        for n <- notifications do
          %{
            "category" => n.category,
            "kind" => n.kind,
            "actor_id" => n.actor_id,
            "subject" => n.subject_type && %{"type" => n.subject_type, "id" => n.subject_id},
            "params" => n.params,
            "count" => n.count,
            "read_at" => n.read_at,
            "created_at" => n.inserted_at,
            "updated_at" => n.last_event_at
          }
        end,
      "settings" => %{
        "channels" => setting.channels,
        "quiet_hours" => %{
          "enabled" => setting.quiet_enabled,
          "start" => setting.quiet_start,
          "end" => setting.quiet_end,
          "time_zone" => setting.time_zone
        }
      },
      "pending_emails" =>
        Repo.all(
          from p in PendingEmail,
            where: p.user_id == ^user_id,
            order_by: p.inserted_at,
            select: %{"category" => p.category, "kind" => p.kind, "inserted_at" => p.inserted_at}
        )
    }
  end

  def delete(user_id) do
    {:ok, _} =
      Repo.transact(fn ->
        for schema <- [Notification, PendingEmail, EmailLog, Setting],
            do: Repo.delete_all(from x in schema, where: x.user_id == ^user_id)

        for table <- ["notification_events", "notification_read_marks"],
            do: Repo.delete_all(from x in table, where: x.user_id == type(^user_id, :binary_id))

        Oban.cancel_all_jobs(
          from j in Oban.Job,
            where: j.worker in ["MlNotifications.EmailWorker", "MlNotifications.DigestWorker"],
            where: fragment("?->>'user_id' = ?", j.args, ^user_id)
        )

        {:ok, nil}
      end)

    :ok
  end
end
