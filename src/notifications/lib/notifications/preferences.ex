defmodule MlNotifications.Preferences do
  @moduledoc """
  Préférences par catégorie et par canal, et heures calmes d'un membre. Les canaux de sécurité ne se coupent pas.
  """
  import Ecto.Query
  alias MlNotifications.{Catalog, Emails, PendingEmail, QuietHours, Repo, Setting}
  alias MlShared.Events

  @channels ~w(in_app email)

  def channels, do: @channels

  @doc "Réglages de `user_id` (valeurs par défaut s'il n'a jamais rien enregistré)."
  def get(user_id), do: Repo.get(Setting, user_id) || %Setting{user_id: user_id}

  @doc "Canal actif pour cette catégorie et cette sorte ?"
  def enabled?(%Setting{} = s, category, channel, kind \\ nil) do
    cond do
      Catalog.locked?(category, channel) ->
        true

      kind && Catalog.mandatory?(kind) ->
        true

      true ->
        get_in(s.channels, [category, channel]) |> boolean(Catalog.default(category, channel))
    end
  end

  defp boolean(value, _default) when is_boolean(value), do: value
  defp boolean(_value, default), do: default

  @doc "Forme du contrat (`GET /api/me/notification-settings`)."
  def to_map(%Setting{} = s, now \\ DateTime.utc_now()) do
    pending =
      Repo.aggregate(from(p in PendingEmail, where: p.user_id == ^s.user_id), :count)

    %{
      "categories" =>
        for category <- Catalog.categories() do
          %{
            "key" => category,
            "in_app" => enabled?(s, category, "in_app"),
            "email" => enabled?(s, category, "email"),
            "locked" => Catalog.locked(category)
          }
        end,
      "quiet_hours" => %{
        "enabled" => s.quiet_enabled,
        "start" => hhmm(s.quiet_start),
        "end" => hhmm(s.quiet_end),
        "time_zone" => s.time_zone,
        "active" => QuietHours.active?(s, now),
        "ends_at" => QuietHours.ends_at(s, now)
      },
      "pending_digest" => %{
        "count" => pending,
        "send_at" => if(pending > 0, do: Emails.digest_at(s.user_id))
      }
    }
  end

  defp hhmm(%Time{} = t), do: t |> Time.truncate(:second) |> Calendar.strftime("%H:%M")

  @doc """
  Changement partiel (`channels` et/ou `quiet_hours`), sérialisé par membre : `{:ok, setting}` ou
  `{:error, {:invalid, erreurs}}` (clés `channels.<catégorie>.<canal>`, `quiet_hours.<champ>`).
  """
  def update(user_id, attrs, now \\ DateTime.utc_now())

  def update(user_id, attrs, now) when is_map(attrs) do
    result =
      Repo.transact(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
          "notification-settings:#{user_id}"
        ])

        setting = get(user_id)

        with {:ok, channels} <- channels(setting.channels, attrs["channels"]),
             {:ok, quiet} <- quiet(setting, attrs["quiet_hours"]) do
          setting
          |> Ecto.Changeset.change(Map.put(quiet, :channels, channels))
          |> Repo.insert_or_update()
        end
      end)

    with {:ok, setting} <- result do
      Emails.reschedule_digest(setting, now)
      Events.broadcast(Events.user(user_id), {:notification_settings_changed, user_id})
      {:ok, setting}
    end
  end

  def update(_user_id, _attrs, _now), do: {:error, {:invalid, %{"base" => ["is invalid"]}}}

  defp channels(current, nil), do: {:ok, current}

  defp channels(current, changes) when is_map(changes) do
    Enum.reduce_while(changes, {:ok, current}, fn {category, values}, {:ok, acc} ->
      cond do
        category not in Catalog.categories() or not is_map(values) ->
          {:halt, invalid("channels.#{label(category)}", "is invalid")}

        true ->
          case category_channels(category, values, Map.get(acc, category, %{})) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, category, value)}}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp channels(_current, _changes), do: invalid("channels", "is invalid")

  defp category_channels(category, values, current) do
    Enum.reduce_while(values, {:ok, current}, fn {channel, value}, {:ok, acc} ->
      field = "channels.#{category}.#{label(channel)}"

      cond do
        channel not in @channels or not is_boolean(value) ->
          {:halt, invalid(field, "is invalid")}

        Catalog.locked?(category, channel) and value == false ->
          {:halt, invalid(field, "is locked")}

        Catalog.locked?(category, channel) ->
          {:cont, {:ok, acc}}

        true ->
          {:cont, {:ok, Map.put(acc, channel, value)}}
      end
    end)
  end

  defp quiet(setting, nil), do: {:ok, Map.take(setting, [:quiet_enabled])}

  defp quiet(setting, attrs) when is_map(attrs) do
    with {:ok, enabled} <- flag(attrs, "enabled", setting.quiet_enabled),
         {:ok, start} <- time(attrs, "start", setting.quiet_start),
         {:ok, finish} <- time(attrs, "end", setting.quiet_end),
         {:ok, zone} <- zone(attrs, setting.time_zone),
         :ok <- different(start, finish),
         :ok <-
           if(enabled and is_nil(zone),
             do: invalid("quiet_hours.time_zone", "can't be blank"),
             else: :ok
           ) do
      {:ok, %{quiet_enabled: enabled, quiet_start: start, quiet_end: finish, time_zone: zone}}
    end
  end

  defp quiet(_setting, _attrs), do: invalid("quiet_hours", "is invalid")

  defp flag(attrs, key, current) do
    case Map.fetch(attrs, key) do
      :error -> {:ok, current}
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _ -> invalid("quiet_hours.#{key}", "is invalid")
    end
  end

  defp time(attrs, key, current) do
    with {:ok, value} <- Map.fetch(attrs, key),
         true <- is_binary(value) and Regex.match?(~r/\A([01]\d|2[0-3]):[0-5]\d\z/, value) do
      {:ok, Time.from_iso8601!(value <> ":00")}
    else
      :error -> {:ok, current}
      false -> invalid("quiet_hours.#{key}", "is invalid")
    end
  end

  defp zone(attrs, current) do
    case Map.fetch(attrs, "time_zone") do
      :error ->
        {:ok, current}

      {:ok, zone} when is_binary(zone) and byte_size(zone) <= 64 ->
        if match?({:ok, _}, DateTime.now(zone)),
          do: {:ok, zone},
          else: invalid("quiet_hours.time_zone", "is not a known time zone")

      _ ->
        invalid("quiet_hours.time_zone", "is not a known time zone")
    end
  end

  defp different(start, finish) do
    if Time.compare(start, finish) == :eq,
      do: invalid("quiet_hours.end", "must differ from the start"),
      else: :ok
  end

  defp label(value) when is_binary(value), do: String.slice(value, 0, 40)
  defp label(_value), do: "?"

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
