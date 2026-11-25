defmodule MysticWeb.SecurityComponents do
  @moduledoc """
  Account security blocks of /settings: two-factor authentication (setup with QR code, one-time display of
  recovery codes, turning off) and active sessions. Events are handled by `MysticWeb.SettingsLive`.
  """
  use MysticWeb, :html

  @doc "Two-factor authentication panel, driven by accounts `GET /api/me/2fa` (`status`)."
  attr :status, :any, required: true, doc: "status map, or :unavailable"
  attr :setup, :map, default: nil, doc: "pending setup: secret, otpauth_uri, qr_svg"
  attr :recovery_codes, :list, default: nil, doc: "codes to show once"
  attr :forms, :map, required: true, doc: "setup, enable, disable and codes forms"

  def two_factor(assigns) do
    ~H"""
    <section class="card space-y-5" id="two-factor" aria-labelledby="two-factor-title">
      <div class="space-y-1">
        <h2 id="two-factor-title" class="text-2xl">{gettext("Two-factor authentication")}</h2>
        <p class="text-sm text-muted">
          {gettext(
            "At login, after your password, we also ask for a 6-digit code from an authenticator app on your phone (Aegis, 1Password, Google Authenticator…)."
          )}
        </p>
      </div>

      <.recovery_codes :if={@recovery_codes} codes={@recovery_codes} />

      <%= cond do %>
        <% @status == :unavailable -> %>
          <.unavailable id="two-factor-unavailable">
            {gettext("Two-factor settings can't be loaded.")}
          </.unavailable>
        <% @status["enabled"] -> %>
          <p id="two-factor-status" class="flex flex-wrap items-center gap-2 text-sm">
            <.tag kind="success" icon="hero-shield-check">{gettext("On")}</.tag>
            <span class="text-muted">
              {gettext("since %{date}", date: date(@status["enabled_at"]))} · {ngettext(
                "1 recovery code left",
                "%{count} recovery codes left",
                @status["recovery_codes_left"]
              )}
            </span>
          </p>
          <.notice :if={@status["recovery_codes_left"] < 4} kind="warning">
            {gettext("You are running out of recovery codes: generate new ones.")}
          </.notice>
          <div class="grid gap-8 lg:grid-cols-2">
            <.form
              for={@forms.codes}
              id="recovery-codes-form"
              phx-submit="regenerate_recovery_codes"
              class="space-y-3"
            >
              <h3 class="font-semibold text-ink">{gettext("New recovery codes")}</h3>
              <p class="text-sm text-muted">{gettext("Your current codes stop working.")}</p>
              <.input
                field={@forms.codes[:password]}
                type="password"
                label={gettext("Current password")}
                autocomplete="current-password"
                required
              />
              <.button type="submit" variant="secondary" phx-disable-with={gettext("Generating…")}>
                {gettext("Generate new codes")}
              </.button>
            </.form>
            <.form
              for={@forms.disable}
              id="two-factor-disable-form"
              phx-submit="disable_two_factor"
              class="space-y-3"
            >
              <h3 class="font-semibold text-ink">{gettext("Turn off")}</h3>
              <.input
                field={@forms.disable[:password]}
                type="password"
                label={gettext("Current password")}
                autocomplete="current-password"
                required
              />
              <.input
                field={@forms.disable[:one_time_password]}
                label={gettext("Authentication code or recovery code")}
                autocomplete="one-time-code"
                autocapitalize="none"
                spellcheck="false"
                required
              />
              <.button type="submit" variant="danger" phx-disable-with={gettext("Turning off…")}>
                {gettext("Turn off two-factor authentication")}
              </.button>
            </.form>
          </div>
        <% @setup -> %>
          <ol id="two-factor-setup" class="space-y-6">
            <li class="space-y-3">
              <p class="font-semibold text-ink">
                {gettext("1. Scan this QR code with your authenticator app")}
              </p>
              <img
                id="two-factor-qr"
                src={"data:image/svg+xml;base64," <> Base.encode64(@setup["qr_svg"])}
                alt={gettext("QR code of your MysticLore secret key")}
                width="232"
                height="232"
                class="qr-code"
              />
              <p class="text-sm text-muted">
                {gettext("Can't scan it? Type this key in the app instead:")}
                <code id="two-factor-secret" class="secret-key">{grouped(@setup["secret"])}</code>
              </p>
            </li>
            <li>
              <.form
                for={@forms.enable}
                id="two-factor-enable-form"
                phx-submit="enable_two_factor"
                class="space-y-3"
              >
                <.input
                  field={@forms.enable[:one_time_password]}
                  label={gettext("2. Enter the 6-digit code it shows")}
                  autocomplete="one-time-code"
                  inputmode="numeric"
                  maxlength="7"
                  required
                />
                <div class="flex flex-wrap gap-2">
                  <.button type="submit" phx-disable-with={gettext("Checking…")}>
                    {gettext("Turn on")}
                  </.button>
                  <.button type="button" variant="ghost" phx-click="cancel_two_factor_setup">
                    {gettext("Cancel")}
                  </.button>
                </div>
              </.form>
            </li>
          </ol>
        <% true -> %>
          <p id="two-factor-status" class="text-sm">
            <.tag kind="neutral">{gettext("Off")}</.tag>
          </p>
          <.form
            for={@forms.setup}
            id="two-factor-setup-form"
            phx-submit="setup_two_factor"
            class="space-y-3"
          >
            <.input
              field={@forms.setup[:password]}
              type="password"
              label={gettext("Current password")}
              hint={gettext("We check it's really you before creating your secret key.")}
              autocomplete="current-password"
              required
            />
            <.button type="submit" phx-disable-with={gettext("Preparing…")}>
              {gettext("Set up two-factor authentication")}
            </.button>
          </.form>
      <% end %>
    </section>
    """
  end

  @doc "Recovery codes, shown once right after they are generated."
  attr :codes, :list, required: true

  def recovery_codes(assigns) do
    ~H"""
    <.notice id="recovery-codes" kind="reward" title={gettext("Save your recovery codes now")}>
      {gettext(
        "If you lose your phone, each code lets you log in once. They won't be shown again: download them or write them down somewhere safe."
      )}
      <ul class="recovery-code-list" aria-label={gettext("Recovery codes")}>
        <li :for={code <- @codes}><code>{code}</code></li>
      </ul>
      <:actions>
        <a
          href={codes_file(@codes)}
          download="mysticlore-recovery-codes.txt"
          class="btn btn-secondary"
        >
          <.icon name="hero-arrow-down-tray" /> {gettext("Download")}
        </a>
        <.button type="button" id="hide-recovery-codes" phx-click="hide_recovery_codes">
          {gettext("I have saved them")}
        </.button>
      </:actions>
    </.notice>
    """
  end

  @doc "Active sessions of accounts `GET /api/me/sessions` (or :unavailable), current one flagged."
  attr :sessions, :any, required: true

  def sessions(assigns) do
    ~H"""
    <section class="card space-y-5" id="active-sessions" aria-labelledby="sessions-title">
      <div class="space-y-1">
        <h2 id="sessions-title" class="text-2xl">{gettext("Active sessions")}</h2>
        <p class="text-sm text-muted">
          {gettext(
            "Browsers signed in to your account. Don't recognise one? Sign it out, then change your password."
          )}
        </p>
      </div>
      <%= if @sessions == :unavailable do %>
        <.unavailable id="sessions-unavailable">
          {gettext("Your sessions can't be listed.")}
        </.unavailable>
      <% else %>
        <ul id="session-list" class="divide-y divide-line">
          <li
            :for={session <- @sessions}
            id={"session-#{session["id"]}"}
            class="flex flex-wrap items-center justify-between gap-3 py-3"
          >
            <div class="min-w-0 space-y-1">
              <p class="flex flex-wrap items-center gap-2 font-medium text-ink">
                <span title={session["user_agent"]}>{device_label(session["user_agent"])}</span>
                <.tag :if={session["current"]} kind="info">{gettext("This browser")}</.tag>
              </p>
              <p class="text-sm text-muted">
                {network(session["ip"])} · {gettext("signed in %{date}",
                  date: date(session["inserted_at"])
                )} · {gettext("last active %{time}", time: message_time(session["last_used_at"]))}
              </p>
            </div>
            <.button
              :if={!session["current"]}
              variant="secondary"
              phx-click="revoke_session"
              phx-value-id={session["id"]}
            >
              {gettext("Sign out")}
            </.button>
          </li>
        </ul>
        <.button
          :if={Enum.any?(@sessions, &(!&1["current"]))}
          id="revoke-other-sessions"
          variant="danger"
          phx-click="revoke_other_sessions"
          data-confirm={gettext("Sign out all your other sessions?")}
        >
          {gettext("Sign out all other sessions")}
        </.button>
      <% end %>
    </section>
    """
  end

  @doc "« Firefox on macOS » from a user agent (best effort)."
  def device_label(ua) when is_binary(ua) do
    browser =
      Enum.find_value(
        [
          {"Edg/", "Edge"},
          {"OPR/", "Opera"},
          {"Firefox/", "Firefox"},
          {"Chrome/", "Chrome"},
          {"CriOS/", "Chrome"},
          {"Safari/", "Safari"}
        ],
        fn {marker, name} -> String.contains?(ua, marker) && name end
      )

    os =
      Enum.find_value(
        [
          {"iPhone", "iOS"},
          {"iPad", "iPadOS"},
          {"Android", "Android"},
          {"Windows", "Windows"},
          {"Mac OS X", "macOS"},
          {"CrOS", "ChromeOS"},
          {"Linux", "Linux"}
        ],
        fn {marker, name} -> String.contains?(ua, marker) && name end
      )

    case {browser, os} do
      {nil, nil} -> String.slice(ua, 0, 40)
      {browser, nil} -> browser
      {nil, os} -> os
      {browser, os} -> gettext("%{browser} on %{os}", browser: browser, os: os)
    end
  end

  def device_label(_), do: gettext("Unknown browser")

  defp network(nil), do: gettext("unknown network")
  defp network(ip), do: gettext("network %{ip}", ip: ip)

  defp grouped(secret),
    do: secret |> String.graphemes() |> Enum.chunk_every(4) |> Enum.map_join(" ", &Enum.join/1)

  defp codes_file(codes) do
    text = "MysticLore recovery codes (each one works once)\n\n" <> Enum.join(codes, "\n") <> "\n"
    "data:text/plain;charset=utf-8," <> URI.encode(text, &URI.char_unreserved?/1)
  end
end
