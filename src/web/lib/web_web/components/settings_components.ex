defmodule MysticWeb.SettingsComponents do
  @moduledoc "Building blocks of `/settings/:section`: navigation, radio groups, checkboxes and save status."
  use MysticWeb, :html

  # offline : leçons gardées sur cet appareil (`MysticWeb.OfflineComponents.settings_section/1`)
  @sections ~w(profile account security preferences accessibility learning notifications privacy data offline)

  def sections, do: @sections

  def section_label("profile"), do: gettext("Profile")
  def section_label("account"), do: gettext("Account")
  def section_label("security"), do: gettext("Security")
  def section_label("preferences"), do: gettext("Preferences")
  def section_label("accessibility"), do: gettext("Accessibility")
  def section_label("learning"), do: gettext("Learning")
  def section_label("notifications"), do: gettext("Notifications")
  def section_label("privacy"), do: gettext("Privacy")
  def section_label("data"), do: gettext("Privacy & data")
  def section_label("offline"), do: gettext("Offline lessons")

  defp section_icon("profile"), do: "hero-user-circle"
  defp section_icon("account"), do: "hero-envelope"
  defp section_icon("security"), do: "hero-shield-check"
  defp section_icon("preferences"), do: "hero-adjustments-horizontal"
  defp section_icon("accessibility"), do: "hero-eye"
  defp section_icon("learning"), do: "hero-academic-cap"
  defp section_icon("notifications"), do: "hero-bell"
  defp section_icon("privacy"), do: "hero-eye-slash"
  defp section_icon("data"), do: "hero-lock-closed"
  defp section_icon("offline"), do: "hero-cloud-arrow-down"

  attr :section, :string, required: true

  def settings_nav(assigns) do
    assigns = assign(assigns, :sections, @sections)

    ~H"""
    <nav id="settings-nav" class="settings-nav" aria-label={gettext("Settings sections")}>
      <ul>
        <li :for={key <- @sections}>
          <.link
            patch={~p"/settings/#{key}"}
            id={"settings-nav-#{key}"}
            class="settings-nav-link"
            aria-current={@section == key && "page"}
          >
            <.icon name={section_icon(key)} />
            <span>{section_label(key)}</span>
          </.link>
        </li>
      </ul>
    </nav>
    """
  end

  @doc "Radio group in a fieldset, with `options` as `[{value, label}]` or `[{value, label, hint}]`."
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :legend, :string, required: true
  attr :value, :any, required: true
  attr :options, :list, required: true
  attr :errors, :list, default: []
  attr :hint, :string, default: nil
  attr :class, :any, default: "choice-grid"
  slot :option_extra, doc: "rendered inside each option, receives the option value"

  def choice_group(assigns) do
    assigns = assign(assigns, :described, described(assigns))

    ~H"""
    <fieldset id={@id} class="space-y-3" aria-describedby={@described}>
      <legend class="label">{@legend}</legend>
      <p :if={@hint} id={"#{@id}-hint"} class="field-hint">{@hint}</p>
      <div class={@class}>
        <label :for={option <- @options} class="choice" for={"#{@id}-#{option_value(option)}"}>
          <input
            type="radio"
            id={"#{@id}-#{option_value(option)}"}
            name={@name}
            value={option_value(option)}
            checked={to_string(@value) == to_string(option_value(option))}
          />
          {render_slot(@option_extra, option_value(option))}
          <span class="min-w-0">
            <span class="block font-medium text-ink">{elem(option, 1)}</span>
            <span :if={tuple_size(option) > 2} class="block text-sm text-muted">{elem(option, 2)}</span>
          </span>
        </label>
      </div>
      <.field_errors id={"#{@id}-error"} errors={@errors} />
    </fieldset>
    """
  end

  defp option_value(option), do: elem(option, 0)

  @doc "Checkbox with its label and hint (an unchecked box still sends `false`)."
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :checked, :boolean, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :value, :string, default: "true"
  attr :unchecked, :any, default: "false", doc: "value sent when unchecked (nil: nothing)"

  def check(assigns) do
    ~H"""
    <div class="choice">
      <input :if={@unchecked} type="hidden" name={@name} value={@unchecked} />
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value={@value}
        checked={@checked}
        aria-describedby={@hint && "#{@id}-hint"}
      />
      <label for={@id} class="min-w-0 flex-1 cursor-pointer">
        <span class="block font-medium text-ink">{@label}</span>
        <span :if={@hint} id={"#{@id}-hint"} class="block text-sm text-muted">{@hint}</span>
      </label>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :errors, :list, required: true

  def field_errors(assigns) do
    ~H"""
    <p :if={@errors != []} id={@id} class="field-error">
      <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
      <span>{Enum.join(Enum.map(@errors, &translate_error/1), " · ")}</span>
    </p>
    """
  end

  @doc "Live status of a form: announced politely, shown only after the service confirmed the save."
  attr :id, :string, required: true
  attr :status, :any, default: nil, doc: "nil or a message"

  def save_status(assigns) do
    ~H"""
    <p id={@id} class="save-status" role="status" aria-live="polite">
      <span :if={@status} class="inline-flex items-center gap-2 text-success">
        <.icon name="hero-check-circle" class="size-5" /> {@status}
      </span>
    </p>
    """
  end

  ## Sections

  @doc "Profile: identity, pronouns, bio, interests and cover, then the avatar."
  attr :user, :map, required: true
  attr :form, :any, required: true
  attr :uploads, :any, required: true
  attr :status, :map, required: true
  attr :errors, :map, required: true

  def profile_section(assigns) do
    ~H"""
    <section id="profile-section" class="card space-y-6" aria-labelledby="profile-title">
      <div class="space-y-2">
        <h2 id="profile-title" class="text-2xl">{gettext("Public profile")}</h2>
        <p id="identity-note" class="text-sm text-muted">
          {gettext(
            "Your display name, username and avatar always stay visible next to what you share: forum posts, messages, friends and lobbies. Who sees the rest of your profile is up to you in Privacy & data."
          )}
          <.link navigate={~p"/members/#{@user["username"]}"} class="link">
            {gettext("View my profile")}
          </.link>
        </p>
      </div>
      <.form for={@form} id="profile-form" phx-submit="save_profile" class="space-y-5">
        <.input
          field={@form[:display_name]}
          label={gettext("Display name")}
          autocomplete="nickname"
          required
        />
        <.input
          field={@form[:pronouns]}
          label={gettext("Pronouns")}
          hint={gettext("Optional, 40 characters at most (for example she/her, they/them).")}
          maxlength="40"
        />
        <.input
          field={@form[:bio]}
          type="textarea"
          rows="4"
          maxlength="500"
          label={gettext("Bio")}
          hint={gettext("A few words about you (optional).")}
        />
        <fieldset id="profile-interests" class="space-y-3" aria-describedby="profile-interests-hint">
          <legend class="label">{gettext("Interests")}</legend>
          <p id="profile-interests-hint" class="field-hint">
            {gettext("Up to 6. They order the adventures recommended on your dashboard.")}
          </p>
          <input type="hidden" name="profile[interests][]" value="" />
          <div class="choice-grid">
            <.check
              :for={key <- MysticWeb.ProfileComponents.interests()}
              id={"interest-#{key}"}
              name="profile[interests][]"
              value={key}
              unchecked={nil}
              checked={key in List.wrap(@form[:interests].value)}
              label={MysticWeb.ProfileComponents.interest_label(key)}
            />
          </div>
          <.field_errors id="profile-interests-error" errors={@form[:interests].errors} />
        </fieldset>
        <.choice_group
          id="profile-cover"
          name="profile[cover]"
          legend={gettext("Cover")}
          value={@form[:cover].value}
          options={
            for cover <- ["default" | MysticWeb.ProfileComponents.covers()],
                do: {cover, MysticWeb.ProfileComponents.cover_label(cover)}
          }
          errors={@form[:cover].errors}
        >
          <:option_extra :let={cover}>
            <.art
              cover={if(cover == "default", do: "hero", else: cover)}
              class="cover-swatch"
              label={false}
            />
          </:option_extra>
        </.choice_group>
        <div class="flex flex-wrap items-center gap-4">
          <.button type="submit" id="save-profile" phx-disable-with={gettext("Saving…")}>
            {gettext("Save profile")}
          </.button>
          <.save_status id="profile-status" status={@status[:profile]} />
        </div>
      </.form>
    </section>

    <section id="avatar-section" class="card space-y-6" aria-labelledby="avatar-title">
      <div class="flex flex-wrap items-center gap-4">
        <.avatar user={@user} size="lg" />
        <div class="min-w-0 flex-1 space-y-1">
          <h2 id="avatar-title" class="text-2xl">{gettext("Avatar")}</h2>
          <p class="text-sm text-muted" id="avatar-current">{avatar_summary(@user["avatar"])}</p>
        </div>
        <.button
          :if={@user["avatar"]}
          type="button"
          variant="ghost"
          id="remove-avatar"
          phx-click="remove_avatar"
        >
          <.icon name="hero-trash" /> {gettext("Use my initials")}
        </.button>
      </div>
      <.form for={%{}} as={:crest} id="crest-form" phx-submit="choose_crest" class="space-y-4">
        <.choice_group
          id="crest-choice"
          name="crest[key]"
          legend={gettext("A crest of the academy")}
          value={@user["avatar"] && @user["avatar"]["kind"] == "crest" && @user["avatar"]["key"]}
          options={for key <- crests(), do: {key, MysticWeb.ProfileComponents.crest_label(key)}}
          errors={@errors[:crest] || []}
        >
          <:option_extra :let={key}>
            <img src={~p"/images/crests/#{key <> ".svg"}"} alt="" class="crest-swatch" />
          </:option_extra>
        </.choice_group>
        <.button type="submit" variant="secondary" id="choose-crest">
          {gettext("Use this crest")}
        </.button>
      </.form>
      <.form
        for={%{}}
        as={:avatar}
        id="avatar-form"
        phx-change="validate_avatar"
        phx-submit="upload_avatar"
        class="space-y-3"
      >
        <div class="field">
          <label for={@uploads.avatar.ref} class="label">{gettext("Or your own image")}</label>
          <.live_file_input
            upload={@uploads.avatar}
            class="input"
            aria-describedby="avatar-hint"
          />
          <p id="avatar-hint" class="field-hint">
            {gettext(
              "PNG, JPEG or WebP, 2 MB at most, 64 to 2048 pixels per side. Hidden data (location, camera, dates) is removed before it is stored."
            )}
          </p>
          <p :for={entry <- @uploads.avatar.entries} class="field-hint">
            {entry.client_name}
            <span :for={err <- upload_errors(@uploads.avatar, entry)} class="text-danger">
              · {upload_error(err)}
            </span>
          </p>
        </div>
        <.field_errors id="avatar-error" errors={@errors[:avatar] || []} />
        <div class="flex flex-wrap items-center gap-4">
          <.button
            type="submit"
            variant="secondary"
            id="upload-avatar"
            phx-disable-with={gettext("Uploading…")}
          >
            <.icon name="hero-arrow-up-tray" /> {gettext("Upload")}
          </.button>
          <.save_status id="avatar-status" status={@status[:avatar]} />
        </div>
      </.form>
    </section>
    """
  end

  defp avatar_summary(%{"kind" => "image"}), do: gettext("Your own image.")

  defp avatar_summary(%{"kind" => "crest", "key" => key}),
    do: gettext("Crest: %{name}.", name: MysticWeb.ProfileComponents.crest_label(key))

  defp avatar_summary(_), do: gettext("Your initials, until you choose a crest or an image.")

  defp upload_error(:too_large), do: gettext("larger than 2 MB")
  defp upload_error(:not_accepted), do: gettext("not a PNG, JPEG or WebP file")
  defp upload_error(:too_many_files), do: gettext("one image at a time")
  defp upload_error(_), do: gettext("can't be uploaded")

  @doc "Account: verified e-mail change, password, summary."
  attr :user, :map, required: true
  attr :email_form, :any, required: true
  attr :email_sent_to, :string, default: nil
  attr :password_form, :any, required: true
  attr :dev_hints, :boolean, default: false

  def account_section(assigns) do
    ~H"""
    <section class="card space-y-5" aria-labelledby="email-title" id="email-section">
      <div class="space-y-1">
        <h2 id="email-title" class="text-2xl">{gettext("Email address")}</h2>
        <p class="text-sm text-muted">
          {gettext(
            "Currently %{email}. A new address replaces it only once you open the link we send to it.",
            email: @user["email"]
          )}
        </p>
      </div>
      <.notice
        :if={@email_sent_to}
        id="email-change-sent"
        kind="success"
        title={gettext("Check your new inbox")}
      >
        {gettext(
          "We sent a confirmation link to %{email} (valid for 24 hours). Open it while logged in to complete the change.",
          email: @email_sent_to
        )}
        <:actions :if={@dev_hints}>
          <.button
            href={MysticWeb.AuthHTML.mailbox_url()}
            variant="secondary"
            target="_blank"
            rel="noopener"
          >
            <.icon name="hero-envelope-open" /> {gettext("Open the dev mailbox")}
          </.button>
        </:actions>
      </.notice>
      <.form for={@email_form} id="email-form" phx-submit="change_email" class="space-y-4">
        <.input
          field={@email_form[:email]}
          type="email"
          label={gettext("New email address")}
          autocomplete="email"
          required
        />
        <.input
          field={@email_form[:password]}
          type="password"
          label={gettext("Current password")}
          autocomplete="current-password"
          required
        />
        <.button type="submit" id="change-email" phx-disable-with={gettext("Sending…")}>
          {gettext("Send the confirmation link")}
        </.button>
      </.form>
    </section>

    <section class="card space-y-5" aria-labelledby="password-title">
      <div class="space-y-1">
        <h2 id="password-title" class="text-2xl">{gettext("Password")}</h2>
        <p class="text-sm text-muted">{gettext("Changing it signs out your other sessions.")}</p>
      </div>
      <.form for={@password_form} id="password-form" phx-submit="change_password" class="space-y-4">
        <.input
          field={@password_form[:current_password]}
          type="password"
          label={gettext("Current password")}
          autocomplete="current-password"
          required
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label={gettext("New password")}
          hint={gettext("At least 12 characters.")}
          autocomplete="new-password"
          minlength="12"
          required
        />
        <.button type="submit" id="change-password" phx-disable-with={gettext("Saving…")}>
          {gettext("Change password")}
        </.button>
      </.form>
    </section>

    <section class="card space-y-3" aria-labelledby="account-title">
      <h2 id="account-title" class="text-2xl">{gettext("Account")}</h2>
      <dl class="summary-list">
        <div>
          <dt>{gettext("Email")}</dt>
          <dd class="break-all">{@user["email"]}</dd>
        </div>
        <div>
          <dt>{gettext("Username")}</dt>
          <dd>@{@user["username"]}</dd>
        </div>
        <div :if={@user["inserted_at"]}>
          <dt>{gettext("Member since")}</dt>
          <dd>{date(@user["inserted_at"])}</dd>
        </div>
      </dl>
      <.link href={~p"/logout"} method="delete" class="btn btn-secondary">
        <.icon name="hero-arrow-left-start-on-rectangle" /> {gettext("Log out")}
      </.link>
    </section>
    """
  end

  # Common zones (an explicit zone set elsewhere, or the device's, is added when missing).
  @zones ~w(Etc/UTC Europe/London Europe/Dublin Europe/Lisbon Europe/Paris Europe/Brussels Europe/Berlin
            Europe/Madrid Europe/Rome Europe/Zurich Europe/Stockholm Europe/Warsaw Europe/Athens
            Europe/Helsinki Europe/Istanbul Europe/Moscow Africa/Casablanca Africa/Dakar Africa/Abidjan
            Africa/Lagos Africa/Cairo Africa/Nairobi Africa/Johannesburg Indian/Antananarivo Indian/Reunion
            Asia/Dubai Asia/Karachi Asia/Kolkata Asia/Bangkok Asia/Singapore Asia/Shanghai Asia/Tokyo
            Australia/Perth Australia/Sydney Pacific/Noumea Pacific/Auckland Pacific/Tahiti Pacific/Honolulu
            America/Anchorage America/Los_Angeles America/Denver America/Chicago America/Mexico_City
            America/New_York America/Toronto America/Martinique America/Cayenne America/Sao_Paulo
            America/Argentina/Buenos_Aires America/Montreal)

  @doc "Time zone choices: automatic (this device), the current zone if unusual, then common zones."
  def zone_options(current, browser) do
    auto =
      if known_zone?(browser),
        do: gettext("Automatic: this device's zone, %{zone}", zone: zone_label(browser)),
        else: gettext("Automatic: this device's zone")

    extra =
      for zone <- [current, browser], zone not in @zones, known_zone?(zone), uniq: true, do: zone

    [{auto, "auto"} | Enum.map(extra ++ @zones, &{zone_label(&1), &1})]
  end

  def theme_label("system"), do: gettext("Device setting")
  def theme_label("light"), do: gettext("Light")
  def theme_label("dark"), do: gettext("Dark")
  def theme_label("grove"), do: gettext("Moonlit grove")
  def theme_label("ember"), do: gettext("Alchemist's ember")
  def theme_label("parchment"), do: gettext("Archivist's parchment")
  def theme_label(other), do: to_string(other)

  @doc "Preferences: language and time zone; appearance (base and VIP themes)."
  attr :preferences, :map, required: true
  attr :time_zone, :string, required: true
  attr :browser_time_zone, :string, default: nil
  attr :theme_paused, :boolean, required: true
  attr :plan, :any, default: nil
  attr :entitlements, :map, default: nil, doc: "billing entitlements (when a VIP access ended)"
  attr :status, :map, required: true
  attr :errors, :map, required: true

  def preferences_section(assigns) do
    assigns =
      assign(assigns,
        access_end: if(assigns.entitlements, do: access_end(assigns.entitlements), else: :none)
      )

    ~H"""
    <section id="language-section" class="card space-y-5" aria-labelledby="language-title">
      <h2 id="language-title" class="text-2xl">{gettext("Language and time zone")}</h2>
      <.form for={%{}} as={:language} id="language-form" phx-submit="save_language" class="space-y-5">
        <.choice_group
          id="language-choice"
          name="language[language]"
          legend={gettext("Language")}
          value={@preferences["language"]}
          options={[
            {"auto", gettext("Automatic"), gettext("Follows the language of this browser.")},
            {"en", "English"},
            {"fr", "Français"}
          ]}
          errors={@errors[:language] || []}
        />
        <.input
          type="select"
          id="time-zone"
          name="language[time_zone]"
          label={gettext("Time zone")}
          value={@preferences["time_zone"]}
          options={zone_options(@preferences["time_zone"], @browser_time_zone)}
          errors={Enum.map(@errors[:time_zone] || [], &translate_error/1)}
          hint={
            gettext("Every date and time is shown in this zone. Now: %{zone}.",
              zone: zone_label(@time_zone)
            )
          }
        />
        <div class="flex flex-wrap items-center gap-4">
          <.button type="submit" id="save-language" phx-disable-with={gettext("Saving…")}>
            {gettext("Save language and time zone")}
          </.button>
          <.save_status id="language-status" status={@status[:language]} />
        </div>
      </.form>
    </section>

    <section id="appearance-section" class="card space-y-5" aria-labelledby="appearance-title">
      <h2 id="appearance-title" class="text-2xl">{gettext("Appearance")}</h2>
      <.access_state
        :if={@theme_paused}
        id="theme-paused"
        icon="hero-sparkles"
        tone="reward"
        heading="h3"
        title={
          case @access_end do
            {:ended, at} when is_binary(at) ->
              gettext("Your VIP access ended on %{date}: VIP theme paused", date: date(at))

            _ ->
              gettext("VIP theme paused")
          end
        }
      >
        {gettext(
          "Your theme « %{theme} » comes back as soon as your VIP membership is active again. Until then, the device setting is used.",
          theme: theme_label(@preferences["theme"])
        )}
        <:actions>
          <.button navigate={~p"/membership"} variant="reward" id="theme-paused-renew">
            <.icon name="hero-sparkles" /> {gettext("Renew VIP")}
          </.button>
        </:actions>
      </.access_state>
      <.form
        for={%{}}
        as={:appearance}
        id="appearance-form"
        phx-submit="save_appearance"
        class="space-y-5"
      >
        <.choice_group
          id="theme-choice"
          name="appearance[theme]"
          legend={gettext("Theme")}
          value={@preferences["theme"]}
          options={[
            {"system", theme_label("system"), gettext("Light or dark, like this device.")},
            {"light", theme_label("light")},
            {"dark", theme_label("dark")}
          ]}
        >
          <:option_extra :let={theme}>
            <span class={["theme-swatch", "theme-swatch-#{theme}"]} aria-hidden="true"></span>
          </:option_extra>
        </.choice_group>
        <.choice_group
          id="vip-theme-choice"
          name="appearance[theme]"
          legend={gettext("VIP themes of the academy")}
          hint={vip_hint(@plan)}
          value={@preferences["theme"]}
          options={for theme <- MysticWeb.Preferences.vip_themes(), do: {theme, theme_label(theme)}}
        >
          <:option_extra :let={theme}>
            <span class={["theme-swatch", "theme-swatch-#{theme}"]} aria-hidden="true"></span>
          </:option_extra>
        </.choice_group>
        <.field_errors id="theme-error" errors={@errors[:theme] || []} />
        <div class="flex flex-wrap items-center gap-4">
          <.button type="submit" id="save-appearance" phx-disable-with={gettext("Saving…")}>
            {gettext("Save appearance")}
          </.button>
          <.save_status id="appearance-status" status={@status[:appearance]} />
        </div>
      </.form>
    </section>

    <section id="welcome-tour-section" class="card space-y-3" aria-labelledby="welcome-tour-title">
      <h2 id="welcome-tour-title" class="text-2xl">{gettext("Welcome tour")}</h2>
      <p class="text-sm text-muted">
        {gettext(
          "Language, interests, daily goal, reading comfort, then adventures chosen for you: five short steps, each saved at once."
        )}
      </p>
      <.button
        type="button"
        id="restart-onboarding"
        variant="secondary"
        phx-click="restart_onboarding"
      >
        <.icon name="hero-arrow-path" /> {gettext("Restart the welcome tour")}
      </.button>
    </section>
    """
  end

  @doc "A data export link that no longer works, explained with the next step (`?export=` of the data section)."
  attr :reason, :string, required: true

  def export_notice(assigns) do
    ~H"""
    <.access_state
      id="export-link-state"
      icon={if @reason == "not_ready", do: "hero-clock", else: "hero-link-slash"}
      tone={if @reason == "not_ready", do: "info", else: "warning"}
      title={
        case @reason do
          "expired" -> gettext("This download link has expired")
          "not_ready" -> gettext("This export isn't ready yet")
          _ -> gettext("This export doesn't exist")
        end
      }
    >
      {case @reason do
        "expired" ->
          gettext(
            "A data export can be downloaded for 24 hours once it is ready, then it is deleted. Ask for a new one below: it takes your password and a few moments."
          )

        "not_ready" ->
          gettext(
            "It is still being assembled (or it failed): its status below updates by itself. You can download it once it says « Ready »."
          )

        _ ->
          gettext(
            "It was deleted, or it belongs to another account. Ask for a new export below if you need one."
          )
      end}
      <:actions>
        <.button href="#your-data" variant="secondary">{gettext("Go to my exports")}</.button>
      </:actions>
    </.access_state>
    """
  end

  @doc "Where the rules about personal data are written (provisional legal pages) and how to ask a question."
  def legal_card(assigns) do
    ~H"""
    <section id="legal-card" class="card space-y-3" aria-labelledby="legal-card-title">
      <h2 id="legal-card-title" class="text-2xl">{gettext("Rules and questions")}</h2>
      <p class="text-sm text-muted">
        {gettext(
          "What each part of MysticLore keeps about you and for how long, the cookies used, and your rights (provisional texts):"
        )}
      </p>
      <ul class="flex flex-wrap gap-x-5 gap-y-1">
        <li>
          <.link navigate={~p"/legal/privacy"} class="help-link" id="data-privacy-link">
            {gettext("Privacy notice")} →
          </.link>
        </li>
        <li>
          <.link navigate={~p"/legal/cookies"} class="help-link" id="data-cookies-link">
            {gettext("Cookies and browser storage")} →
          </.link>
        </li>
        <li>
          <.link navigate={~p"/legal/terms"} class="help-link" id="data-terms-link">
            {gettext("Terms of use")} →
          </.link>
        </li>
        <li>
          <.link
            navigate={~p"/contact?#{[topic: "privacy"]}"}
            class="help-link"
            id="data-contact-link"
          >
            {gettext("Ask a question about my data")} →
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  defp vip_hint("vip"), do: gettext("Included in your VIP membership.")

  defp vip_hint(:unavailable),
    do: gettext("They need an active VIP membership, checked when you save.")

  defp vip_hint(_plan), do: gettext("They need an active VIP membership (see Membership).")

  @doc "Accessibility: motion, contrast, text size, links, captions."
  attr :preferences, :map, required: true
  attr :status, :map, required: true
  attr :errors, :map, required: true

  def accessibility_section(assigns) do
    ~H"""
    <section id="accessibility-section" class="card space-y-5" aria-labelledby="accessibility-title">
      <div class="space-y-1">
        <h2 id="accessibility-title" class="text-2xl">{gettext("Accessibility")}</h2>
        <p class="text-sm text-muted">
          {gettext("Applied at once on every page, on every device you use.")}
        </p>
      </div>
      <.form
        for={%{}}
        as={:accessibility}
        id="accessibility-form"
        phx-submit="save_accessibility"
        class="space-y-5"
      >
        <div class="grid gap-2">
          <.check
            id="a11y-reduce-motion"
            name="accessibility[reduce_motion]"
            checked={@preferences["reduce_motion"]}
            label={gettext("Reduce motion")}
            hint={gettext("No animations or transitions, even if your device doesn't ask for it.")}
          />
          <.check
            id="a11y-high-contrast"
            name="accessibility[high_contrast]"
            checked={@preferences["high_contrast"]}
            label={gettext("High contrast")}
            hint={gettext("Secondary text as strong as the main text, marked borders and focus.")}
          />
          <.check
            id="a11y-underline-links"
            name="accessibility[underline_links]"
            checked={@preferences["underline_links"]}
            label={gettext("Underline links")}
          />
          <.check
            id="a11y-captions"
            name="accessibility[captions]"
            checked={@preferences["captions"]}
            label={gettext("Captions on by default in video lessons")}
            hint={gettext("In the language of the interface when the video has it.")}
          />
        </div>
        <.choice_group
          id="text-size-choice"
          name="accessibility[text_size]"
          legend={gettext("Text size")}
          value={@preferences["text_size"]}
          options={for size <- [100, 112, 125, 150], do: {size, "#{size} %"}}
          errors={@errors[:text_size] || []}
          class="choice-row"
        />
        <div class="flex flex-wrap items-center gap-4">
          <.button type="submit" id="save-accessibility" phx-disable-with={gettext("Saving…")}>
            {gettext("Save accessibility settings")}
          </.button>
          <.save_status id="accessibility-status" status={@status[:accessibility]} />
        </div>
      </.form>
    </section>
    """
  end

  @doc "Learning: daily XP goal; how the interests order the recommendations."
  attr :preferences, :map, required: true
  attr :user, :map, required: true
  attr :status, :map, required: true
  attr :errors, :map, required: true

  def learning_section(assigns) do
    ~H"""
    <section id="learning-section" class="card space-y-5" aria-labelledby="learning-title">
      <h2 id="learning-title" class="text-2xl">{gettext("Learning")}</h2>
      <.form for={%{}} as={:learning} id="learning-form" phx-submit="save_learning" class="space-y-5">
        <.choice_group
          id="daily-goal-choice"
          name="learning[daily_xp_goal]"
          legend={gettext("Daily XP goal")}
          hint={
            gettext(
              "Your dashboard shows your progress towards it during the academy day, which starts at midnight UTC for everyone."
            )
          }
          value={@preferences["daily_xp_goal"]}
          options={[
            {10, gettext("10 XP"), gettext("A quick lesson")},
            {20, gettext("20 XP"), gettext("A steady pace")},
            {50, gettext("50 XP"), gettext("An ambitious day")},
            {100, gettext("100 XP"), gettext("A true quest")}
          ]}
          errors={@errors[:daily_xp_goal] || []}
        />
        <div class="flex flex-wrap items-center gap-4">
          <.button type="submit" id="save-learning" phx-disable-with={gettext("Saving…")}>
            {gettext("Save daily goal")}
          </.button>
          <.save_status id="learning-status" status={@status[:learning]} />
        </div>
      </.form>
      <div id="interests-note" class="space-y-2 border-t border-line pt-5">
        <h3 class="text-xl">{gettext("Recommendations")}</h3>
        <p class="text-sm text-muted">
          {gettext(
            "Adventures matching your interests are recommended first on your dashboard (the categories you chose most come first)."
          )}
        </p>
        <p :if={(@user["interests"] || []) != []} class="text-sm">
          {Enum.map_join(@user["interests"], ", ", &MysticWeb.ProfileComponents.interest_label/1)}
        </p>
        <.link patch={~p"/settings/profile"} class="link text-sm">{gettext("Choose my interests")} →</.link>
      </div>
    </section>
    """
  end

  @doc "Notifications section: the category and channel matrix, then quiet hours."
  attr :settings, :any, required: true, doc: "center settings, or :unavailable"
  attr :preferences, :map, required: true
  attr :time_zone, :string, required: true
  attr :status, :map, required: true
  attr :errors, :map, required: true

  def notifications_section(%{settings: :unavailable} = assigns) do
    ~H"""
    <.unavailable id="notification-settings-unavailable">
      {gettext("Your notification settings can't be loaded right now.")}
    </.unavailable>
    """
  end

  def notifications_section(assigns) do
    quiet = assigns.settings["quiet_hours"] || %{}
    pending = assigns.settings["pending_digest"] || %{}

    assigns =
      assign(assigns,
        quiet: quiet,
        pending: pending,
        zone_source:
          if(assigns.preferences["time_zone"] == "auto",
            do: gettext("detected from this browser"),
            else: gettext("from your preferences")
          ),
        other_zone:
          quiet["time_zone"] && quiet["time_zone"] != assigns.time_zone && quiet["time_zone"]
      )

    ~H"""
    <section
      id="notification-channels-section"
      class="card space-y-5"
      aria-labelledby="notification-channels-title"
    >
      <div class="space-y-1">
        <h2 id="notification-channels-title" class="text-2xl">{gettext("What reaches me")}</h2>
        <p class="text-sm text-muted">
          {gettext(
            "In the app: the bell and your notifications page. By e-mail: a short message without any private content (never the text of a message), with a link back here."
          )}
        </p>
      </div>
      <.form
        for={%{}}
        as={:channels}
        id="notification-channels-form"
        phx-submit="save_notification_channels"
        class="space-y-5"
      >
        <table class="notification-matrix">
          <caption class="sr-only">{gettext("Notification channels by category")}</caption>
          <thead>
            <tr>
              <th scope="col">{gettext("Category")}</th>
              <th scope="col">{gettext("In the app")}</th>
              <th scope="col">{gettext("By e-mail")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={c <- @settings["categories"]} id={"channels-#{c["key"]}"}>
              <th scope="row">
                <span class="block font-medium text-ink">
                  {MysticWeb.Notifications.category_label(c["key"])}
                </span>
                <span class="block text-sm text-muted" id={"channels-#{c["key"]}-hint"}>
                  {MysticWeb.Notifications.category_hint(c["key"])}
                </span>
              </th>
              <td :for={channel <- ~w(in_app email)}>
                <.channel_cell category={c} channel={channel} />
              </td>
            </tr>
          </tbody>
        </table>
        <.field_errors id="notification-channels-error" errors={@errors[:channels] || []} />
        <div class="flex flex-wrap items-center gap-4">
          <.button type="submit" id="save-notification-channels" phx-disable-with={gettext("Saving…")}>
            {gettext("Save notification choices")}
          </.button>
          <.save_status id="notification-channels-status" status={@status[:notification_channels]} />
        </div>
      </.form>
    </section>

    <section id="quiet-hours-section" class="card space-y-5" aria-labelledby="quiet-hours-title">
      <div class="space-y-1">
        <h2 id="quiet-hours-title" class="text-2xl">{gettext("Quiet hours")}</h2>
        <p class="text-sm text-muted">
          {gettext(
            "During quiet hours: no e-mail (they are gathered into one summary sent when quiet hours end) and no pop-up. Your bell and your notifications page still update, silently. Security notices are never held back."
          )}
        </p>
      </div>
      <.form
        for={%{}}
        as={:quiet}
        id="quiet-hours-form"
        phx-submit="save_quiet_hours"
        class="space-y-5"
      >
        <.check
          id="quiet-enabled"
          name="quiet[enabled]"
          checked={@quiet["enabled"] == true}
          label={gettext("Turn on quiet hours")}
        />
        <.field_errors id="quiet-enabled-error" errors={@errors[:quiet_enabled] || []} />
        <div class="quiet-times">
          <div class="space-y-1">
            <label for="quiet-start" class="label">{gettext("From")}</label>
            <input
              type="time"
              id="quiet-start"
              name="quiet[start]"
              value={@quiet["start"]}
              class="input"
              required
              aria-describedby="quiet-time-zone"
            />
            <.field_errors id="quiet-start-error" errors={@errors[:quiet_start] || []} />
          </div>
          <div class="space-y-1">
            <label for="quiet-end" class="label">{gettext("Until")}</label>
            <input
              type="time"
              id="quiet-end"
              name="quiet[end]"
              value={@quiet["end"]}
              class="input"
              required
              aria-describedby="quiet-time-zone"
            />
            <.field_errors id="quiet-end-error" errors={@errors[:quiet_end] || []} />
          </div>
        </div>
        <p id="quiet-time-zone" class="text-sm">
          {gettext("Time zone: %{zone}, %{source}.",
            zone: zone_label(@time_zone),
            source: @zone_source
          )}
          <.link patch={~p"/settings/preferences"} class="link">{gettext("Change it")}</.link>
        </p>
        <.field_errors id="quiet-time-zone-error" errors={@errors[:quiet_time_zone] || []} />
        <p :if={@other_zone} id="quiet-other-zone" class="text-sm text-muted">
          {gettext(
            "Your quiet hours were saved with %{zone}; saving again will use the time zone above.",
            zone: @other_zone
          )}
        </p>
        <p :if={@quiet["enabled"] && @quiet["active"]} id="quiet-active" class="text-sm">
          <.icon name="hero-moon" class="size-4" />
          {gettext("Quiet hours are on right now, until %{time}.", time: time(@quiet["ends_at"]))}
        </p>
        <p :if={(@pending["count"] || 0) > 0} id="quiet-pending" class="text-sm">
          {ngettext(
            "%{count} e-mail is waiting: it will be sent in one summary at %{time}.",
            "%{count} e-mails are waiting: they will be sent in one summary at %{time}.",
            @pending["count"],
            time: datetime(@pending["send_at"])
          )}
        </p>
        <div class="flex flex-wrap items-center gap-4">
          <.button type="submit" id="save-quiet-hours" phx-disable-with={gettext("Saving…")}>
            {gettext("Save quiet hours")}
          </.button>
          <.save_status id="quiet-hours-status" status={@status[:quiet_hours]} />
        </div>
      </.form>
    </section>
    """
  end

  attr :category, :map, required: true
  attr :channel, :string, required: true

  defp channel_cell(assigns) do
    key = assigns.category["key"]

    assigns =
      assign(assigns,
        key: key,
        id: "channel-#{key}-#{assigns.channel}",
        locked: assigns.channel in (assigns.category["locked"] || []),
        label: channel_label(key, assigns.channel)
      )

    ~H"""
    <span :if={@locked} id={"#{@id}-locked"} class="channel-locked" title={@label}>
      <.icon name="hero-lock-closed" class="size-4" />
      <span>{gettext("Always")}</span>
      <span class="sr-only">{@label}</span>
    </span>
    <label :if={!@locked} class="channel-toggle" for={@id}>
      <input type="hidden" name={"channels[#{@key}][#{@channel}]"} value="false" />
      <input
        type="checkbox"
        id={@id}
        name={"channels[#{@key}][#{@channel}]"}
        value="true"
        checked={@category[@channel] == true}
        aria-describedby={"channels-#{@key}-hint"}
      />
      <span class="sr-only">{@label}</span>
    </label>
    """
  end

  defp channel_label(key, "in_app"),
    do: gettext("%{category} in the app", category: MysticWeb.Notifications.category_label(key))

  defp channel_label(key, "email"),
    do: gettext("%{category} by e-mail", category: MysticWeb.Notifications.category_label(key))

  @doc "Privacy section, whose settings are held and checked by social."
  attr :settings, :any, required: true, doc: "social settings, or :unavailable"
  attr :status, :map, required: true
  attr :errors, :map, required: true

  def privacy_section(%{settings: :unavailable} = assigns) do
    ~H"""
    <.unavailable id="privacy-unavailable">
      {gettext("Your privacy settings can't be loaded right now.")}
    </.unavailable>
    """
  end

  def privacy_section(assigns) do
    ~H"""
    <section id="presence-section" class="card space-y-5" aria-labelledby="presence-title">
      <div class="space-y-1">
        <h2 id="presence-title" class="text-2xl">{gettext("What my friends see")}</h2>
        <p class="text-sm text-muted">
          {gettext(
            "Only your friends can ever see these. Nothing is kept about when you were last online."
          )}
        </p>
      </div>
      <.form
        for={%{}}
        as={:presence}
        id="presence-form"
        phx-submit="save_social_visibility"
        class="space-y-5"
      >
        <div class="grid gap-2">
          <.check
            id="privacy-show-online"
            name="presence[show_online]"
            checked={@settings["show_online"]}
            label={gettext("Show my friends when I'm online")}
            hint={gettext("A dot next to your name while one of your pages is open.")}
          />
          <.field_errors id="privacy-show-online-error" errors={@errors[:show_online] || []} />
          <.check
            id="privacy-read-receipts"
            name="presence[read_receipts]"
            checked={@settings["read_receipts"]}
            label={gettext("Read receipts")}
            hint={
              gettext(
                "Others see when you have read their messages (« Seen »). It works both ways: turned off, you don't see theirs either."
              )
            }
          />
          <.field_errors id="privacy-read-receipts-error" errors={@errors[:read_receipts] || []} />
        </div>
        <div class="flex flex-wrap items-center gap-4">
          <.button type="submit" id="save-presence" phx-disable-with={gettext("Saving…")}>
            {gettext("Save")}
          </.button>
          <.save_status id="presence-status" status={@status[:social_visibility]} />
        </div>
      </.form>
    </section>

    <section id="contacts-section" class="card space-y-5" aria-labelledby="contacts-title">
      <div class="space-y-1">
        <h2 id="contacts-title" class="text-2xl">{gettext("Who can contact me")}</h2>
        <p class="text-sm text-muted">
          {gettext("A refused attempt is told to the other member, without anything else about you.")}
        </p>
      </div>
      <.form
        for={%{}}
        as={:contacts}
        id="contacts-form"
        phx-submit="save_contact_permissions"
        class="space-y-6"
      >
        <.choice_group
          id="privacy-friend-requests"
          name="contacts[friend_requests]"
          legend={gettext("Who can send me a friend request")}
          value={@settings["friend_requests"]}
          options={[
            {"everyone", gettext("Everyone")},
            {"friends_of_friends", gettext("Friends of my friends"),
             gettext("Members who share at least one friend with you.")},
            {"nobody", gettext("Nobody")}
          ]}
          errors={@errors[:friend_requests] || []}
        />
        <.choice_group
          id="privacy-group-adds"
          name="contacts[group_adds]"
          legend={gettext("Who can add me to a group")}
          value={@settings["group_adds"]}
          options={[{"friends", gettext("My friends")}, {"nobody", gettext("Nobody")}]}
          errors={@errors[:group_adds] || []}
          class="choice-row"
        />
        <.choice_group
          id="privacy-lobby-invites"
          name="contacts[lobby_invites]"
          legend={gettext("Who can invite me to a multiplayer activity")}
          value={@settings["lobby_invites"]}
          options={[{"friends", gettext("My friends")}, {"nobody", gettext("Nobody")}]}
          errors={@errors[:lobby_invites] || []}
          class="choice-row"
        />
        <div class="flex flex-wrap items-center gap-4">
          <.button type="submit" id="save-contacts" phx-disable-with={gettext("Saving…")}>
            {gettext("Save contact permissions")}
          </.button>
          <.save_status id="contacts-status" status={@status[:contacts]} />
        </div>
      </.form>
    </section>
    """
  end

  @doc "Privacy & data: who sees the rest of the profile, and a preview through accounts' own filter."
  attr :user, :map, required: true
  attr :preview, :any, default: nil
  attr :status, :map, required: true
  attr :errors, :map, required: true

  def data_section(assigns) do
    ~H"""
    <section id="visibility-section" class="card space-y-5" aria-labelledby="visibility-title">
      <div class="space-y-1">
        <h2 id="visibility-title" class="text-2xl">{gettext("Who can see my profile")}</h2>
        <p class="text-sm text-muted">
          {gettext(
            "Your display name, username and avatar always stay visible next to what you share. This setting covers your bio, pronouns, interests and academy record."
          )}
        </p>
      </div>
      <.form
        for={%{}}
        as={:visibility}
        id="visibility-form"
        phx-submit="save_visibility"
        class="space-y-5"
      >
        <.choice_group
          id="visibility-choice"
          name="visibility[profile_visibility]"
          legend={gettext("The rest of my profile is visible to")}
          value={@user["profile_visibility"] || "members"}
          options={
            for v <- MysticWeb.ProfileComponents.visibilities(),
                do:
                  {v, MysticWeb.ProfileComponents.visibility_label(v),
                   MysticWeb.ProfileComponents.visibility_hint(v)}
          }
          errors={@errors[:profile_visibility] || []}
        />
        <div class="flex flex-wrap items-center gap-4">
          <.button type="submit" id="save-visibility" phx-disable-with={gettext("Saving…")}>
            {gettext("Save visibility")}
          </.button>
          <.save_status id="visibility-status" status={@status[:visibility]} />
        </div>
      </.form>

      <div class="space-y-3 border-t border-line pt-5">
        <h3 class="text-xl">{gettext("Preview my profile")}</h3>
        <p class="text-sm text-muted">
          {gettext("Exactly what each reader receives: the same filter as your real profile page.")}
        </p>
        <div class="flex flex-wrap gap-2" role="group" aria-label={gettext("Preview as")}>
          <.button
            :for={as <- ~w(visitor member friend)}
            type="button"
            id={"preview-as-#{as}"}
            variant={if @preview && @preview.as == as, do: "primary", else: "secondary"}
            phx-click="preview"
            phx-value-as={as}
            aria-pressed={to_string(!!(@preview && @preview.as == as))}
          >
            {preview_label(as)}
          </.button>
        </div>
        <div :if={@preview} id="profile-preview" class="preview-frame space-y-4">
          <p class="text-sm text-muted" role="status">{preview_caption(@preview.as)}</p>
          <MysticWeb.ProfileComponents.profile_card
            id="preview-profile"
            name_id="preview-name"
            heading="h3"
            profile={@preview.profile}
          />
          <MysticWeb.ProfileComponents.record_card
            :if={@preview.record}
            id="preview-record"
            equipped_id="preview-equipped"
            record={@preview.record}
          />
        </div>
      </div>
    </section>
    """
  end

  defp preview_label("visitor"), do: gettext("As a visitor")
  defp preview_label("member"), do: gettext("As a member")
  defp preview_label("friend"), do: gettext("As a friend")

  defp preview_caption("visitor"),
    do: gettext("Your profile as a visitor who is not signed in sees it:")

  defp preview_caption("member"),
    do: gettext("Your profile as a signed-in member who isn't your friend sees it:")

  defp preview_caption("friend"), do: gettext("Your profile as one of your friends sees it:")

  defp described(%{id: id, hint: hint, errors: errors}) do
    case Enum.reject([hint && "#{id}-hint", errors != [] && "#{id}-error"], &(!&1)) do
      [] -> nil
      ids -> Enum.join(ids, " ")
    end
  end
end
