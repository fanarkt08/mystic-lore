defmodule MysticWeb.Preferences.FormatTimeZoneTest do
  @moduledoc "`MysticWeb.Format`: the single utility turning service timestamps into dates and times."
  use ExUnit.Case, async: true
  alias MysticWeb.Format

  setup do
    Gettext.put_locale(MysticWeb.Gettext, "en")
    :ok
  end

  test "converts to the zone of the process and names it" do
    Format.put_time_zone("Europe/Paris")
    assert Format.datetime("2026-11-23T23:30:00Z") == "Nov 24, 2026 · 00:30 CET"
    # the date of a timestamp is its date in that zone; a plain date stays as it is
    assert Format.date("2026-11-23T23:30:00Z") == "Nov 24, 2026"
    assert Format.date("2026-11-23") == "Nov 23, 2026"
    assert Format.time("2026-07-01T12:00:05Z", seconds: true) == "14:00:05 CEST"

    Format.put_time_zone("Asia/Tokyo")
    assert Format.time("2026-11-23T09:30:00Z") == "18:30 JST"
    assert Format.zone_label() =~ "Asia/Tokyo (UTC+09:00)"
  end

  test "unknown or missing zones fall back to UTC; bad timestamps stay harmless" do
    Format.put_time_zone("Mars/Olympus_Mons")
    assert Format.time_zone() == "Etc/UTC"
    assert Format.time("2026-11-23T09:30:00Z") == "09:30 UTC"
    Format.put_time_zone(nil)
    assert Format.datetime("not a date") == "—"
    assert Format.message_time(nil) == ""
  end

  test "datetime-local inputs are read in the zone of the process (DST gaps handled)" do
    Format.put_time_zone("America/New_York")
    assert Format.from_local_input("2026-11-24T18:00") == {:ok, "2026-11-24T23:00:00Z"}
    # 02:30 doesn't exist on 2026-03-08 in New York: the first valid instant after the gap
    assert Format.from_local_input("2026-03-08T02:30") == {:ok, "2026-03-08T07:00:00Z"}
    assert Format.from_local_input("tomorrow") == :error
  end

  test "French dates" do
    Gettext.put_locale(MysticWeb.Gettext, "fr")
    Format.put_time_zone("Europe/Paris")
    assert Format.datetime("2026-11-23T08:05:00Z") =~ ~r/^23 \S+ 2026 · 09:05 CET$/
  end
end
