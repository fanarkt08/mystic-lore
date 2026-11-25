defmodule MysticWeb.Format do
  @moduledoc """
  Locale-aware formatting of service data. It is the only place where a service timestamp becomes text.
  """
  use Gettext, backend: MysticWeb.Gettext

  defp locale, do: Gettext.get_locale(MysticWeb.Gettext)

  @zone_key :mystic_time_zone

  @doc "Sets the time zone used by the date functions in this process (unknown zone → UTC)."
  def put_time_zone(zone) do
    Process.put(@zone_key, if(known_zone?(zone), do: zone, else: "Etc/UTC"))
    :ok
  end

  @doc "Time zone of this process (`Etc/UTC` by default)."
  def time_zone, do: Process.get(@zone_key, "Etc/UTC")

  @doc "IANA name known to the bundled time zone database."
  def known_zone?(zone) when is_binary(zone) and byte_size(zone) <= 64,
    do: match?({:ok, _}, DateTime.now(zone))

  def known_zone?(_zone), do: false

  @doc "Now, in the zone of this process."
  def now, do: DateTime.now!(time_zone())

  @doc "\"Europe/Paris (UTC+01:00)\": the zone of this process and its current offset."
  def zone_label(zone \\ time_zone()) do
    offset =
      case DateTime.now(zone) do
        {:ok, dt} -> utc_offset(dt.utc_offset + dt.std_offset)
        _ -> "UTC"
      end

    "#{zone} (#{offset})"
  end

  defp utc_offset(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    seconds = abs(seconds)
    "UTC#{sign}#{pad(div(seconds, 3600))}:#{pad(div(rem(seconds, 3600), 60))}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # ISO 8601 timestamp → DateTime in the zone of this process
  defp local(iso) do
    with {:ok, dt, _offset} <- DateTime.from_iso8601(to_string(iso)),
         {:ok, local} <- DateTime.shift_zone(dt, time_zone()) do
      {:ok, local}
    else
      _ -> :error
    end
  end

  @doc "`2.5, 1` → \"2.5\" (en) / \"2,5\" (fr): a number with a fixed count of decimals."
  def decimal(number, decimals)
      when is_number(number) and is_integer(decimals) and decimals >= 0 do
    text = :erlang.float_to_binary(number / 1, decimals: decimals)
    if locale() == "fr", do: String.replace(text, ".", ","), else: text
  end

  @doc "`1200, \"usd\"` → \"$12\" (en) / \"12 $ US\" (fr); cents shown only when needed."
  def money(cents, currency) when is_integer(cents) do
    amount =
      if rem(cents, 100) == 0,
        do: Integer.to_string(div(cents, 100)),
        else: :erlang.float_to_binary(cents / 100, decimals: 2)

    code = String.downcase(to_string(currency))

    case {locale(), code} do
      {"fr", "usd"} -> String.replace(amount, ".", ",") <> " $ US"
      {"fr", "eur"} -> String.replace(amount, ".", ",") <> " €"
      {"fr", _} -> String.replace(amount, ".", ",") <> " " <> String.upcase(code)
      {_, "usd"} -> "$" <> amount
      {_, "eur"} -> "€" <> amount
      {_, _} -> amount <> " " <> String.upcase(code)
    end
  end

  def money(_cents, _currency), do: "—"

  @doc "Formats an ISO date, or the local date of a timestamp, as « Nov 23, 2026 »."
  def date(iso) do
    case to_date(iso) do
      {:ok, d} -> day_text(d, true)
      _ -> "—"
    end
  end

  @doc "Formats a timestamp as « Nov 23, 2026 · 14:05 CET »."
  def datetime(iso) do
    case local(iso) do
      {:ok, dt} -> "#{day_text(DateTime.to_date(dt), true)} · #{clock(dt)}"
      _ -> "—"
    end
  end

  @doc "Timestamp → \"14:05 CET\" (the hour alone; `seconds: true` → \"14:05:32 CET\")."
  def time(iso, opts \\ []) do
    case local(iso) do
      {:ok, dt} -> if opts[:seconds], do: clock(dt, "%H:%M:%S"), else: clock(dt)
      _ -> ""
    end
  end

  @doc "Short timestamp for lists and messages: \"14:05 CET\" today, else \"Nov 23 · 14:05 CET\"."
  def message_time(iso) do
    case local(iso) do
      {:ok, dt} ->
        d = DateTime.to_date(dt)

        if d == DateTime.to_date(now()),
          do: clock(dt),
          else: "#{day_text(d, false)} · #{clock(dt)}"

      _ ->
        ""
    end
  end

  @doc """
  Relative time for activity lists, in the zone of this process: \"just now\", \"5 min ago\", then
  \"Today · 14:05 CET\", \"Yesterday · 09:12 CET\", else `message_time/1` (\"Nov 21 · 18:00 CET\").
  """
  def relative(iso, now \\ DateTime.utc_now()) do
    with {:ok, dt, _offset} <- DateTime.from_iso8601(to_string(iso)),
         {:ok, local} <- DateTime.shift_zone(dt, time_zone()),
         {:ok, local_now} <- DateTime.shift_zone(now, time_zone()) do
      seconds = DateTime.diff(now, dt)
      day = DateTime.to_date(local)
      today = DateTime.to_date(local_now)

      cond do
        seconds < 60 -> gettext("just now")
        seconds < 3600 -> gettext("%{count} min ago", count: div(seconds, 60))
        day == today -> gettext("Today · %{time}", time: clock(local))
        day == Date.add(today, -1) -> gettext("Yesterday · %{time}", time: clock(local))
        true -> message_time(iso)
      end
    else
      _ -> ""
    end
  end

  @doc "`datetime-local` input value (zone of this process) → UTC ISO 8601, or `:error`."
  def from_local_input(value) when is_binary(value) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(String.pad_trailing(value, 19, ":00")),
         {:ok, dt} <- local_datetime(naive) do
      {:ok,
       dt
       |> DateTime.shift_zone!("Etc/UTC")
       |> DateTime.truncate(:second)
       |> DateTime.to_iso8601()}
    else
      _ -> :error
    end
  end

  def from_local_input(_value), do: :error

  defp local_datetime(naive) do
    case DateTime.from_naive(naive, time_zone()) do
      {:ok, dt} -> {:ok, dt}
      # a time skipped by a DST change: the first valid instant after it; a repeated one: the first
      {:gap, _before, after_gap} -> {:ok, after_gap}
      {:ambiguous, first, _second} -> {:ok, first}
      error -> error
    end
  end

  defp clock(dt, format \\ "%H:%M"), do: Calendar.strftime(dt, format) <> " " <> dt.zone_abbr

  defp day_text(d, year?) do
    case {locale(), year?} do
      {"fr", true} -> "#{d.day} #{month(d.month)} #{d.year}"
      {"fr", false} -> "#{d.day} #{month(d.month)}"
      {_, true} -> "#{month(d.month)} #{d.day}, #{d.year}"
      {_, false} -> "#{month(d.month)} #{d.day}"
    end
  end

  @doc "Abbreviated weekday of an ISO date (activity chart)."
  def weekday(iso) do
    case to_date(iso) do
      {:ok, d} -> d |> Date.day_of_week() |> day()
      _ -> ""
    end
  end

  # a timestamp gives its date in the zone of this process; a plain date is kept as is
  defp to_date(iso) when is_binary(iso) do
    case local(iso) do
      {:ok, dt} -> {:ok, DateTime.to_date(dt)}
      :error -> Date.from_iso8601(iso)
    end
  end

  defp to_date(_), do: :error

  defp month(1), do: pgettext("month", "Jan")
  defp month(2), do: pgettext("month", "Feb")
  defp month(3), do: pgettext("month", "Mar")
  defp month(4), do: pgettext("month", "Apr")
  defp month(5), do: pgettext("month", "May")
  defp month(6), do: pgettext("month", "Jun")
  defp month(7), do: pgettext("month", "Jul")
  defp month(8), do: pgettext("month", "Aug")
  defp month(9), do: pgettext("month", "Sep")
  defp month(10), do: pgettext("month", "Oct")
  defp month(11), do: pgettext("month", "Nov")
  defp month(12), do: pgettext("month", "Dec")

  defp day(1), do: pgettext("weekday", "Mon")
  defp day(2), do: pgettext("weekday", "Tue")
  defp day(3), do: pgettext("weekday", "Wed")
  defp day(4), do: pgettext("weekday", "Thu")
  defp day(5), do: pgettext("weekday", "Fri")
  defp day(6), do: pgettext("weekday", "Sat")
  defp day(7), do: pgettext("weekday", "Sun")

  @doc "Initials of a display name (avatar placeholder)."
  def initials(name) do
    name
    |> to_string()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      initials -> initials
    end
  end

  ## Contract enums

  def category_label("coding"), do: gettext("Coding")
  def category_label("science"), do: gettext("Science")
  def category_label("humanities"), do: gettext("Humanities")
  def category_label("creative"), do: gettext("Creative")
  def category_label(other), do: to_string(other)

  def difficulty_label("beginner"), do: gettext("Beginner")
  def difficulty_label("intermediate"), do: gettext("Intermediate")
  def difficulty_label("advanced"), do: gettext("Advanced")
  def difficulty_label(other), do: to_string(other)

  def kind_label("story"), do: gettext("Story")
  def kind_label("exercise"), do: gettext("Quiz")
  def kind_label("coding"), do: gettext("Coding")
  def kind_label("video"), do: gettext("Video")
  def kind_label("simulation"), do: gettext("Simulation")
  def kind_label("minigame"), do: gettext("Mini-game")
  def kind_label(other), do: to_string(other)

  def kind_icon("story"), do: "hero-book-open"
  def kind_icon("exercise"), do: "hero-puzzle-piece"
  def kind_icon("coding"), do: "hero-code-bracket"
  def kind_icon("video"), do: "hero-film"
  def kind_icon("simulation"), do: "hero-beaker"
  def kind_icon("minigame"), do: "hero-squares-2x2"
  def kind_icon(_), do: "hero-sparkles"

  def subscription_status_label("active"), do: gettext("Active")
  def subscription_status_label("past_due"), do: gettext("Payment past due")
  def subscription_status_label("canceled"), do: gettext("Canceled")
  def subscription_status_label(_), do: gettext("No subscription")

  def invoice_status_label("paid"), do: gettext("Paid")
  def invoice_status_label("failed"), do: gettext("Payment failed")
  def invoice_status_label(other), do: to_string(other)
end
