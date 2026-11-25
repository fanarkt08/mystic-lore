defmodule MlNotifications.QuietHours do
  @moduledoc """
  Heures calmes dans le fuseau IANA du membre, changements d'heure compris.
  """
  alias MlNotifications.Setting

  @doc "Heures calmes en cours à l'instant `now` (UTC) ?"
  def active?(%Setting{quiet_enabled: true, time_zone: zone} = s, %DateTime{} = now)
      when is_binary(zone) do
    case DateTime.shift_zone(now, zone) do
      {:ok, local} -> inside?(DateTime.to_time(local), s.quiet_start, s.quiet_end)
      _ -> false
    end
  end

  def active?(_setting, _now), do: false

  # plage [start, end[ ; `start > end` : elle passe minuit
  defp inside?(time, start, finish) do
    if Time.compare(start, finish) == :lt,
      do: not before?(time, start) and before?(time, finish),
      else: not before?(time, start) or before?(time, finish)
  end

  defp before?(a, b), do: Time.compare(a, b) == :lt

  @doc "Fin (UTC) des heures calmes en cours à `now`, `nil` si elles ne sont pas en cours."
  def ends_at(%Setting{} = s, %DateTime{} = now) do
    if active?(s, now) do
      {:ok, local} = DateTime.shift_zone(now, s.time_zone)
      date = DateTime.to_date(local)

      # plage qui passe minuit et heure locale après le début : la fin est demain
      date =
        if Time.compare(s.quiet_start, s.quiet_end) != :lt and
             not before?(DateTime.to_time(local), s.quiet_start),
           do: Date.add(date, 1),
           else: date

      date |> instant(s.quiet_end, s.time_zone, now) |> DateTime.shift_zone!("Etc/UTC")
    end
  end

  defp instant(date, time, zone, now) do
    case DateTime.new(date, time, zone) do
      {:ok, dt} -> dt
      {:gap, _before, after_gap} -> after_gap
      {:ambiguous, first, second} -> if DateTime.after?(first, now), do: first, else: second
    end
  end

  @doc "Secondes jusqu'à la fin des heures calmes en cours (0 si elles ne le sont pas)."
  def seconds_left(%Setting{} = s, %DateTime{} = now) do
    case ends_at(s, now) do
      nil -> 0
      at -> max(DateTime.diff(at, now), 0)
    end
  end
end
