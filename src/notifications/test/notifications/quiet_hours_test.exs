defmodule MlNotifications.QuietHoursTest do
  @moduledoc "Heures calmes en Europe/Paris, de part et d'autre des changements d'heure de 2026 (29 mars, 25 octobre)."
  use ExUnit.Case, async: true
  alias MlNotifications.{QuietHours, Setting}

  defp quiet(start, finish, zone \\ "Europe/Paris"),
    do: %Setting{quiet_enabled: true, quiet_start: start, quiet_end: finish, time_zone: zone}

  test "a plain evening and morning (winter time, UTC+1)" do
    s = quiet(~T[22:00:00], ~T[07:00:00])
    refute QuietHours.active?(s, ~U[2026-01-15 20:59:00Z])
    assert QuietHours.active?(s, ~U[2026-01-15 21:00:00Z])
    assert QuietHours.ends_at(s, ~U[2026-01-15 21:00:00Z]) == ~U[2026-01-16 06:00:00Z]
    assert QuietHours.active?(s, ~U[2026-01-16 05:59:00Z])
    refute QuietHours.active?(s, ~U[2026-01-16 06:00:00Z])
    assert QuietHours.ends_at(s, ~U[2026-01-16 06:00:00Z]) == nil
  end

  test "spring forward (29 March 2026, 02:00 CET → 03:00 CEST): the night is one hour shorter" do
    s = quiet(~T[22:00:00], ~T[07:00:00])
    # 22:30 CET on the 28th
    start = ~U[2026-03-28 21:30:00Z]
    assert QuietHours.active?(s, start)
    # the end is 07:00 CEST, i.e. 05:00 UTC (not 06:00 as the night before)
    assert QuietHours.ends_at(s, start) == ~U[2026-03-29 05:00:00Z]
    assert DateTime.diff(QuietHours.ends_at(s, start), start, :hour) == 7
    # 06:30 CEST: still quiet; 07:30 CEST: over
    assert QuietHours.active?(s, ~U[2026-03-29 04:30:00Z])
    refute QuietHours.active?(s, ~U[2026-03-29 05:30:00Z])
  end

  test "fall back (25 October 2026, 03:00 CEST → 02:00 CET): the night is one hour longer" do
    s = quiet(~T[22:00:00], ~T[07:00:00])
    start = ~U[2026-10-24 20:00:00Z]
    assert QuietHours.active?(s, start)
    assert QuietHours.ends_at(s, start) == ~U[2026-10-25 06:00:00Z]
    assert DateTime.diff(QuietHours.ends_at(s, start), start, :hour) == 10
    assert QuietHours.active?(s, ~U[2026-10-25 05:30:00Z])
    refute QuietHours.active?(s, ~U[2026-10-25 06:00:00Z])
  end

  test "an end inside the skipped hour ends at the first valid instant after it" do
    s = quiet(~T[23:00:00], ~T[02:30:00])
    # 01:45 CET on the 29th
    now = ~U[2026-03-29 00:45:00Z]
    assert QuietHours.active?(s, now)
    # 02:30 does not exist that night: 03:00 CEST = 01:00 UTC
    assert QuietHours.ends_at(s, now) == ~U[2026-03-29 01:00:00Z]
    refute QuietHours.active?(s, ~U[2026-03-29 01:00:00Z])
  end

  test "an end inside the repeated hour: the first occurrence still to come" do
    s = quiet(~T[01:00:00], ~T[02:30:00])
    # 01:30 CEST (first pass of the night): ends at 02:30 CEST = 00:30 UTC
    assert QuietHours.ends_at(s, ~U[2026-10-24 23:30:00Z]) == ~U[2026-10-25 00:30:00Z]
    # 02:15 CET (second pass, after the change): 02:30 CEST is past, so 02:30 CET = 01:30 UTC
    now = ~U[2026-10-25 01:15:00Z]
    assert QuietHours.active?(s, now)
    assert QuietHours.ends_at(s, now) == ~U[2026-10-25 01:30:00Z]
    assert QuietHours.seconds_left(s, now) == 15 * 60
  end

  test "another zone, a daytime range; disabled or without a zone: never quiet" do
    tokyo = quiet(~T[09:00:00], ~T[17:00:00], "Asia/Tokyo")
    assert QuietHours.active?(tokyo, ~U[2026-11-24 00:00:00Z])
    assert QuietHours.ends_at(tokyo, ~U[2026-11-24 00:00:00Z]) == ~U[2026-11-24 08:00:00Z]
    refute QuietHours.active?(tokyo, ~U[2026-11-24 08:00:00Z])

    refute QuietHours.active?(%{tokyo | quiet_enabled: false}, ~U[2026-11-24 00:00:00Z])
    refute QuietHours.active?(%{tokyo | time_zone: nil}, ~U[2026-11-24 00:00:00Z])
    refute QuietHours.active?(%{tokyo | time_zone: "Mars/Olympus"}, ~U[2026-11-24 00:00:00Z])
    assert QuietHours.seconds_left(%{tokyo | quiet_enabled: false}, ~U[2026-11-24 00:00:00Z]) == 0
  end
end
