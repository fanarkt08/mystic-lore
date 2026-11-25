defmodule MysticWeb.SettingsLive do
  @moduledoc """
  Settings in sections, each saved by the service that holds it. The session token only travels in a header.
  """
  use MysticWeb, :live_view
  import MysticWeb.SettingsComponents
  alias MysticWeb.{Auth, Preferences}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       profile_form: profile_form(socket.assigns.current_user, []),
       password_form: password_form([]),
       email_form: blank_form(:email_change, [:email, :password]),
       email_sent_to: nil,
       totp_setup: nil,
       recovery_codes: nil,
       two_factor_forms: two_factor_forms(),
       two_factor: nil,
       sessions: nil,
       exports: nil,
       social_settings: nil,
       notification_settings: nil,
       plan: nil,
       entitlements: nil,
       export_notice: nil,
       preview: nil,
       status: %{},
       errors: %{},
       export_form: blank_form(:data_export, [:password]),
       deletion_form: blank_form(:account_deletion, [:password, :confirm_username]),
       dev_hints: Application.get_env(:web, :dev_hints, false)
     )
     |> allow_upload(:avatar,
       accept: ~w(.png .jpg .jpeg .webp),
       max_entries: 1,
       max_file_size: 2_097_152
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    section = params["section"] || "profile"
    if section not in sections(), do: raise(MysticWeb.NotFoundError)

    {:noreply,
     socket
     |> assign(
       section: section,
       page_title: gettext("Settings · %{section}", section: section_label(section)),
       # a download link that no longer works (`MysticWeb.Privacy.ExportController`), explained in this section
       export_notice:
         if(section == "data" and params["export"] in ~w(expired not_ready missing),
           do: params["export"]
         )
     )
     |> load_section(section)}
  end

  defp load_section(socket, "security"), do: socket |> load_two_factor() |> load_sessions()
  defp load_section(socket, "data"), do: load_exports(socket)
  defp load_section(socket, "preferences"), do: load_plan(socket)
  defp load_section(socket, "privacy"), do: load_social_settings(socket)
  defp load_section(socket, "notifications"), do: load_notification_settings(socket)
  defp load_section(socket, _section), do: socket

  defp profile_form(user, errors) do
    user
    |> Map.take(~w(display_name bio pronouns))
    |> Map.merge(%{"interests" => user["interests"] || [], "cover" => user["cover"] || "default"})
    |> to_form(as: :profile, errors: errors)
  end

  defp password_form(errors),
    do: to_form(%{"current_password" => "", "password" => ""}, as: :password, errors: errors)

  # Secrets (passwords, codes) are never sent back to the browser: forms are rebuilt empty.
  defp blank_form(as, fields, values \\ %{}, errors \\ []) do
    fields
    |> Map.new(&{Atom.to_string(&1), ""})
    |> Map.merge(values)
    |> to_form(as: as, errors: errors)
  end

  defp two_factor_forms(errors \\ %{}) do
    %{
      setup: blank_form(:two_factor_setup, [:password], %{}, errors[:setup] || []),
      enable: blank_form(:two_factor_enable, [:one_time_password], %{}, errors[:enable] || []),
      disable:
        blank_form(
          :two_factor_disable,
          [:password, :one_time_password],
          %{},
          errors[:disable] || []
        ),
      codes: blank_form(:recovery_codes, [:password], %{}, errors[:codes] || [])
    }
  end

  defp load_two_factor(socket) do
    case Api.get(socket, :accounts, "/api/me/2fa") do
      {:ok, %{"enabled" => _} = status} -> assign(socket, two_factor: status)
      _ -> assign(socket, two_factor: :unavailable)
    end
  end

  defp load_sessions(socket) do
    case Api.get(socket, :accounts, "/api/me/sessions", headers: Auth.session_headers(socket)) do
      {:ok, %{"sessions" => sessions}} when is_list(sessions) ->
        assign(socket, sessions: sessions)

      _ ->
        assign(socket, sessions: :unavailable)
    end
  end

  defp load_exports(socket) do
    case Api.get(socket, :accounts, "/api/me/exports") do
      {:ok, %{"exports" => exports}} when is_list(exports) -> assign(socket, exports: exports)
      _ -> assign(socket, exports: :unavailable)
    end
  end

  defp load_social_settings(socket) do
    case Api.get(socket, :social, "/api/me/settings") do
      {:ok, %{"settings" => %{} = settings}} -> assign(socket, social_settings: settings)
      _ -> assign(socket, social_settings: :unavailable)
    end
  end

  defp load_notification_settings(socket) do
    case Api.get(socket, :notifications, "/api/me/notification-settings") do
      {:ok, %{"settings" => %{"categories" => _} = settings}} ->
        assign(socket, notification_settings: settings)

      _ ->
        assign(socket, notification_settings: :unavailable)
    end
  end

  # Shown next to the VIP themes only (accounts checks the plan again when one is saved); the entitlements tell
  # when a VIP access ended (paused theme).
  defp load_plan(socket) do
    case Api.get(socket, :billing, "/api/me/billing") do
      {:ok, %{"entitlements" => %{"plan" => plan} = entitlements}} ->
        assign(socket, plan: plan, entitlements: entitlements)

      _ ->
        assign(socket, plan: :unavailable, entitlements: nil)
    end
  end

  # A session was revoked somewhere (this page is still valid, or `MysticWeb.Auth` would have left it).
  @impl true
  def handle_info({:sessions_revoked, _user_id}, %{assigns: %{section: "security"}} = socket),
    do: {:noreply, load_sessions(socket)}

  def handle_info({:data_export_changed, _user_id}, %{assigns: %{section: "data"}} = socket),
    do: {:noreply, load_exports(socket)}

  def handle_info(
        {:social_settings_changed, _user_id},
        %{assigns: %{section: "privacy"}} = socket
      ),
      do: {:noreply, load_social_settings(socket)}

  def handle_info(
        {:entitlements_changed, _id, _plan},
        %{assigns: %{section: "preferences"}} = socket
      ),
      do: {:noreply, load_plan(socket)}

  def handle_info(
        {:notification_settings_changed, _user_id},
        %{assigns: %{section: "notifications"}} = socket
      ),
      do: {:noreply, load_notification_settings(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Saves: the member returned by accounts becomes the current one, then the preferences are re-applied.

  defp saved(socket, key, user, message) do
    socket
    |> assign(current_user: user, errors: Map.drop(socket.assigns.errors, fields(key)))
    |> Preferences.refresh()
    |> assign(status: Map.put(socket.assigns.status, key, "#{message} #{saved_at()}"))
  end

  # the time makes a repeated save announced again
  defp saved_at, do: time(DateTime.to_iso8601(DateTime.utc_now()), seconds: true)

  defp fields(:avatar), do: [:avatar, :crest]
  defp fields(:language), do: [:language, :time_zone]
  defp fields(:appearance), do: [:theme]

  defp fields(:accessibility),
    do: [:reduce_motion, :high_contrast, :text_size, :underline_links, :captions]

  defp fields(:learning), do: [:daily_xp_goal]
  defp fields(:visibility), do: [:profile_visibility]
  defp fields(:social_visibility), do: [:show_online, :read_receipts]
  defp fields(:contacts), do: [:friend_requests, :group_adds, :lobby_invites]
  defp fields(:notification_channels), do: [:channels]
  defp fields(:quiet_hours), do: [:quiet_enabled, :quiet_start, :quiet_end, :quiet_time_zone]
  defp fields(_key), do: []

  # Field errors of a refused save (`422` of accounts, or a reason given for one field).
  defp refused(socket, key, errors) do
    errors = Map.new(errors, fn {field, messages} -> {field, List.wrap(messages)} end)

    assign(socket,
      errors: socket.assigns.errors |> Map.drop(fields(key)) |> Map.merge(errors),
      status: Map.delete(socket.assigns.status, key)
    )
  end

  defp invalid(error, key) do
    error |> Api.form_errors(fields(key)) |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp save_preferences(socket, key, attrs, message) do
    case Api.patch(socket, :accounts, "/api/me/preferences", json: attrs) do
      {:ok, %{"user" => %{"id" => _} = user}} ->
        {:ok, saved(socket, key, user, message)}

      {:error, {:http, 422, _}} = error ->
        {:error, refused(socket, key, invalid(error, key))}

      {:error, {:http, 403, %{"error" => "vip_required"}}} ->
        message = gettext("VIP themes need an active VIP membership.")
        {:error, refused(socket, key, theme: {message, []})}

      {:error, {:http, 503, %{"error" => "entitlements_unavailable"}}} ->
        message =
          gettext(
            "Your membership can't be verified right now, so this theme can't be saved yet."
          )

        {:error, refused(socket, key, theme: {message, []})}

      error ->
        {:error, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  @impl true
  def handle_event("save_profile", %{"profile" => params}, socket) do
    attrs = %{
      display_name: String.trim(to_string(params["display_name"])),
      bio: to_string(params["bio"]),
      pronouns: to_string(params["pronouns"]),
      interests: params |> Map.get("interests", []) |> List.wrap() |> Enum.reject(&(&1 == "")),
      cover: if(params["cover"] in [nil, "", "default"], do: nil, else: params["cover"])
    }

    case Api.patch(socket, :accounts, "/api/me", json: attrs) do
      {:ok, %{"user" => %{"id" => _} = user}} ->
        {:noreply,
         socket
         |> saved(:profile, user, gettext("Profile saved."))
         |> assign(profile_form: profile_form(user, []))}

      {:error, {:http, 422, _}} = error ->
        errors = Api.form_errors(error, [:display_name, :bio, :pronouns, :interests, :cover])
        form = to_form(Map.put_new(params, "interests", []), as: :profile, errors: errors)
        {:noreply, socket |> assign(profile_form: form) |> refused(:profile, [])}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("validate_avatar", _params, socket), do: {:noreply, socket}

  def handle_event("upload_avatar", _params, socket) do
    case consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
           {:ok, File.read!(path)}
         end) do
      [bytes] ->
        Api.put(socket, :accounts, "/api/me/avatar",
          body: bytes,
          headers: [{"content-type", "application/octet-stream"}],
          receive_timeout: 15_000
        )
        |> avatar_result(socket, gettext("Avatar saved."))

      [] ->
        message = gettext("Choose an image first (PNG, JPEG or WebP, 2 MB at most).")
        {:noreply, refused(socket, :avatar, avatar: {message, []})}
    end
  end

  def handle_event("choose_crest", %{"crest" => %{"key" => crest}}, socket) do
    socket
    |> Api.put(:accounts, "/api/me/avatar/crest", json: %{crest: crest})
    |> avatar_result(socket, gettext("Crest chosen."))
  end

  def handle_event("choose_crest", _params, socket) do
    {:noreply, refused(socket, :avatar, crest: {gettext("Choose a crest first."), []})}
  end

  def handle_event("remove_avatar", _params, socket) do
    socket
    |> Api.delete(:accounts, "/api/me/avatar")
    |> avatar_result(socket, gettext("Avatar removed: your initials are shown instead."))
  end

  def handle_event("save_language", %{"language" => params}, socket) do
    attrs = Map.take(params, ~w(language time_zone))
    before = Gettext.get_locale(MysticWeb.Gettext)

    case save_preferences(socket, :language, attrs, gettext("Language and time zone saved.")) do
      {:ok, socket} ->
        locale = locale(socket)

        if locale == before do
          {:noreply, socket}
        else
          # every text of the page and `<html lang>` change: full reload, confirmation in the new language
          Gettext.put_locale(MysticWeb.Gettext, locale)

          {:noreply,
           socket
           |> put_flash(:info, gettext("Language and time zone saved."))
           |> redirect(to: ~p"/settings/preferences")}
        end

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  def handle_event("save_appearance", %{"appearance" => %{"theme" => theme}}, socket) do
    {_result, socket} =
      save_preferences(socket, :appearance, %{theme: theme}, gettext("Appearance saved."))

    {:noreply, socket}
  end

  def handle_event("save_accessibility", %{"accessibility" => params}, socket) do
    attrs =
      params
      |> Map.take(~w(reduce_motion high_contrast underline_links captions text_size))
      |> Map.new(fn
        {"text_size", value} -> {"text_size", value}
        {key, value} -> {key, value == "true"}
      end)

    {_result, socket} =
      save_preferences(socket, :accessibility, attrs, gettext("Accessibility settings saved."))

    {:noreply, socket}
  end

  # Welcome tour proposed again (accounts `onboarding.status` = `pending`), then opened at once.
  def handle_event("restart_onboarding", _params, socket) do
    case Api.put(socket, :accounts, "/api/me/onboarding", json: %{status: "pending"}) do
      {:ok, %{"user" => %{"id" => _} = user}} ->
        {:noreply, socket |> assign(current_user: user) |> push_navigate(to: ~p"/welcome")}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("save_learning", %{"learning" => %{"daily_xp_goal" => goal}}, socket) do
    {_result, socket} =
      save_preferences(socket, :learning, %{daily_xp_goal: goal}, gettext("Daily goal saved."))

    {:noreply, socket}
  end

  def handle_event("save_visibility", %{"visibility" => %{"profile_visibility" => value}}, socket) do
    case Api.patch(socket, :accounts, "/api/me", json: %{profile_visibility: value}) do
      {:ok, %{"user" => %{"id" => _} = user}} ->
        {:noreply,
         socket
         |> saved(:visibility, user, gettext("Profile visibility saved."))
         |> assign(preview: nil)}

      {:error, {:http, 422, _}} = error ->
        {:noreply, refused(socket, :visibility, invalid(error, :visibility))}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("save_social_visibility", %{"presence" => params}, socket) do
    attrs =
      Map.new(Map.take(params, ~w(show_online read_receipts)), fn {k, v} -> {k, v == "true"} end)

    save_social(socket, :social_visibility, attrs, gettext("Visibility saved."))
  end

  def handle_event("save_contact_permissions", %{"contacts" => params}, socket) do
    attrs = Map.take(params, ~w(friend_requests group_adds lobby_invites))
    save_social(socket, :contacts, attrs, gettext("Contact permissions saved."))
  end

  # Same filter as the real profile page: accounts decides, for a visitor, a member or a friend.
  def handle_event("preview", %{"as" => as}, socket) do
    case Api.get(socket, :accounts, "/api/me/profile-preview", params: [as: as]) do
      {:ok, %{"profile" => %{"id" => id} = profile}} ->
        record =
          if profile["academy_record"] do
            case Api.get(socket, :learning, "/api/users/:id/profile", path_params: [id: id]) do
              {:ok, %{"level" => _} = record} -> record
              _ -> :unavailable
            end
          end

        {:noreply, assign(socket, preview: %{as: as, profile: profile, record: record})}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("change_password", %{"password" => params}, socket) do
    body = %{current_password: params["current_password"], password: params["password"]}

    case Api.put(socket, :accounts, "/api/me/password",
           json: body,
           headers: Auth.session_headers(socket)
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(password_form: password_form([]))
         |> put_flash(
           :info,
           gettext("Password changed. Your other sessions have been signed out.")
         )}

      {:error, {:http, 422, _}} = error ->
        {:noreply,
         assign(socket, password_form: password_form(Api.form_errors(error, [:password])))}

      error ->
        case credential_error(error) do
          {:flash, message} ->
            {:noreply, put_flash(socket, :error, message)}

          {_field, message} ->
            {:noreply,
             assign(socket, password_form: password_form(current_password: {message, []}))}
        end
    end
  end

  def handle_event("change_email", %{"email_change" => params}, socket) do
    email = String.trim(to_string(params["email"]))
    body = %{email: email, password: to_string(params["password"])}

    retry = fn errors ->
      blank_form(:email_change, [:email, :password], %{"email" => email}, errors)
    end

    case Api.post(socket, :accounts, "/api/me/email", json: body) do
      {:ok, _} ->
        {:noreply,
         assign(socket,
           email_form: blank_form(:email_change, [:email, :password]),
           email_sent_to: email
         )}

      {:error, {:http, 422, _}} = error ->
        {:noreply, assign(socket, email_form: retry.(Api.form_errors(error, [:email])))}

      {:error, {:http, 429, %{"error" => "rate_limited"}}} ->
        message = gettext("Too many email change requests. Please try again in an hour.")
        {:noreply, socket |> assign(email_form: retry.([])) |> put_flash(:error, message)}

      error ->
        case credential_error(error) do
          {:flash, message} ->
            {:noreply, put_flash(socket, :error, message)}

          {_field, message} ->
            {:noreply, assign(socket, email_form: retry.(password: {message, []}))}
        end
    end
  end

  def handle_event("setup_two_factor", %{"two_factor_setup" => %{"password" => password}}, socket) do
    case Api.post(socket, :accounts, "/api/me/2fa/setup", json: %{password: password}) do
      {:ok, %{"secret" => _, "qr_svg" => _} = setup} ->
        {:noreply, assign(socket, totp_setup: setup, two_factor_forms: two_factor_forms())}

      {:error, {:http, 409, _}} ->
        {:noreply, load_two_factor(socket)}

      error ->
        {:noreply, two_factor_error(socket, :setup, error)}
    end
  end

  def handle_event(
        "enable_two_factor",
        %{"two_factor_enable" => %{"one_time_password" => code}},
        socket
      ) do
    case Api.post(socket, :accounts, "/api/me/2fa/enable", json: %{code: String.trim(code)}) do
      {:ok, %{"recovery_codes" => codes}} when is_list(codes) ->
        {:noreply,
         socket
         |> assign(totp_setup: nil, recovery_codes: codes, two_factor_forms: two_factor_forms())
         |> load_two_factor()
         |> put_flash(:info, gettext("Two-factor authentication is on."))}

      {:error, {:http, 409, _}} ->
        message = gettext("This setup is no longer valid. Please start again.")

        {:noreply,
         socket |> assign(totp_setup: nil) |> load_two_factor() |> put_flash(:error, message)}

      error ->
        {:noreply, two_factor_error(socket, :enable, error)}
    end
  end

  def handle_event("cancel_two_factor_setup", _params, socket),
    do: {:noreply, assign(socket, totp_setup: nil)}

  def handle_event("disable_two_factor", %{"two_factor_disable" => params}, socket) do
    body = %{
      password: params["password"],
      code: String.trim(to_string(params["one_time_password"]))
    }

    case Api.post(socket, :accounts, "/api/me/2fa/disable", json: body) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(recovery_codes: nil, two_factor_forms: two_factor_forms())
         |> load_two_factor()
         |> put_flash(:info, gettext("Two-factor authentication is off."))}

      {:error, {:http, 409, _}} ->
        {:noreply, load_two_factor(socket)}

      error ->
        {:noreply, two_factor_error(socket, :disable, error)}
    end
  end

  def handle_event(
        "regenerate_recovery_codes",
        %{"recovery_codes" => %{"password" => password}},
        socket
      ) do
    case Api.post(socket, :accounts, "/api/me/2fa/recovery-codes", json: %{password: password}) do
      {:ok, %{"recovery_codes" => codes}} when is_list(codes) ->
        {:noreply,
         socket
         |> assign(recovery_codes: codes, two_factor_forms: two_factor_forms())
         |> load_two_factor()}

      {:error, {:http, 409, _}} ->
        {:noreply, load_two_factor(socket)}

      error ->
        {:noreply, two_factor_error(socket, :codes, error)}
    end
  end

  def handle_event("hide_recovery_codes", _params, socket),
    do: {:noreply, assign(socket, recovery_codes: nil)}

  def handle_event("revoke_session", %{"id" => id}, socket) do
    path = "/api/me/sessions/" <> URI.encode(to_string(id), &URI.char_unreserved?/1)

    case Api.delete(socket, :accounts, path, headers: Auth.session_headers(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_sessions()
         |> put_flash(:info, gettext("That session has been signed out."))}

      {:error, {:http, status, _}} when status in [404, 409] ->
        {:noreply, load_sessions(socket)}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("revoke_other_sessions", _params, socket) do
    case Api.delete(socket, :accounts, "/api/me/sessions", headers: Auth.session_headers(socket)) do
      {:ok, _} ->
        message = gettext("All your other sessions have been signed out.")
        {:noreply, socket |> load_sessions() |> put_flash(:info, message)}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  def handle_event("request_export", %{"data_export" => %{"password" => password}}, socket) do
    case Api.post(socket, :accounts, "/api/me/exports", json: %{password: password}) do
      {:ok, %{"id" => _}} ->
        message = gettext("We're preparing your data. It will appear below when it's ready.")

        {:noreply,
         socket
         |> assign(export_form: blank_form(:data_export, [:password]))
         |> load_exports()
         |> put_flash(:info, message)}

      {:error, {:http, 429, %{"error" => "rate_limited"}}} ->
        message = gettext("You can request at most 3 exports per day. Please try again later.")

        {:noreply,
         socket
         |> assign(export_form: blank_form(:data_export, [:password]))
         |> put_flash(:error, message)}

      error ->
        case credential_error(error) do
          {:flash, message} ->
            {:noreply, put_flash(socket, :error, message)}

          {_field, message} ->
            form = blank_form(:data_export, [:password], %{}, password: {message, []})
            {:noreply, assign(socket, export_form: form)}
        end
    end
  end

  def handle_event("refresh_exports", _params, socket), do: {:noreply, load_exports(socket)}

  def handle_event("delete_account", %{"account_deletion" => params}, socket) do
    username = String.trim(to_string(params["confirm_username"]))
    body = %{password: to_string(params["password"]), confirm_username: username}

    retry = fn errors ->
      blank_form(
        :account_deletion,
        [:password, :confirm_username],
        %{"confirm_username" => username},
        errors
      )
    end

    case Api.post(socket, :accounts, "/api/me/deletion", json: body) do
      {:ok, %{"deletion_scheduled_at" => at}} ->
        # every session (this one included) has just been revoked: back to the login page
        message =
          gettext(
            "Your account will be deleted on %{date}. You have been signed out everywhere: log in again before that date if you want to cancel.",
            date: date(at)
          )

        {:noreply, socket |> put_flash(:info, message) |> redirect(to: ~p"/login")}

      {:error, {:http, 422, _}} = error ->
        errors =
          case Api.form_errors(error, [:confirm_username]) do
            [] -> [confirm_username: {gettext("This is not your username."), []}]
            errors -> errors
          end

        {:noreply, assign(socket, deletion_form: retry.(errors))}

      error ->
        case credential_error(error) do
          {:flash, message} ->
            {:noreply, socket |> assign(deletion_form: retry.([])) |> put_flash(:error, message)}

          {_field, message} ->
            {:noreply, assign(socket, deletion_form: retry.(password: {message, []}))}
        end
    end
  end

  def handle_event("cancel_deletion", _params, socket),
    do: {:noreply, MysticWeb.Privacy.cancel_deletion(socket)}

  # Every configurable cell is sent (an unchecked box sends `false`); locked cells are never sent.
  def handle_event("save_notification_channels", params, socket) do
    channels =
      for {category, values} <- Map.get(params, "channels", %{}),
          category in MysticWeb.Notifications.categories(),
          is_map(values),
          into: %{} do
        {category,
         for(
           {channel, value} <- values,
           channel in ~w(in_app email),
           into: %{},
           do: {channel, value == "true"}
         )}
      end

    save_notification_settings(
      socket,
      :notification_channels,
      %{channels: channels},
      gettext("Notification choices saved.")
    )
  end

  # Quiet hours apply in the page's effective zone: the member's, or this browser's when it is `auto`.
  def handle_event("save_quiet_hours", %{"quiet" => params}, socket) do
    attrs = %{
      quiet_hours: %{
        enabled: params["enabled"] == "true",
        start: params["start"],
        end: params["end"],
        time_zone: MysticWeb.Format.time_zone()
      }
    }

    save_notification_settings(socket, :quiet_hours, attrs, gettext("Quiet hours saved."))
  end

  defp save_notification_settings(socket, key, attrs, message) do
    case Api.patch(socket, :notifications, "/api/me/notification-settings", json: attrs) do
      {:ok, %{"settings" => %{"categories" => _} = settings}} ->
        {:noreply,
         socket
         |> assign(
           notification_settings: settings,
           errors: Map.drop(socket.assigns.errors, fields(key))
         )
         |> assign(status: Map.put(socket.assigns.status, key, "#{message} #{saved_at()}"))}

      {:error, {:http, 422, %{"errors" => errors}}} when is_map(errors) ->
        {:noreply, refused(socket, key, notification_errors(errors))}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  # `quiet_hours.start` → `quiet_start`, `channels.<category>.<channel>` → `channels` (next to the matrix)
  defp notification_errors(errors) do
    for {name, messages} <- errors, message <- List.wrap(messages), is_binary(message) do
      field =
        case name do
          "quiet_hours.enabled" -> :quiet_enabled
          "quiet_hours.start" -> :quiet_start
          "quiet_hours.end" -> :quiet_end
          "quiet_hours.time_zone" -> :quiet_time_zone
          _channels -> :channels
        end

      {field, {message, []}}
    end
  end

  # Social settings: the values returned by social become the shown ones; errors sit next to their field.
  defp save_social(socket, key, attrs, message) do
    case Api.patch(socket, :social, "/api/me/settings", json: attrs) do
      {:ok, %{"settings" => %{} = settings}} ->
        {:noreply,
         socket
         |> assign(
           social_settings: settings,
           errors: Map.drop(socket.assigns.errors, fields(key))
         )
         |> assign(status: Map.put(socket.assigns.status, key, "#{message} #{saved_at()}"))}

      {:error, {:http, 422, _}} = error ->
        {:noreply, refused(socket, key, invalid(error, key))}

      error ->
        {:noreply, put_flash(socket, :error, Api.error_message(error))}
    end
  end

  defp avatar_result({:ok, %{"user" => %{"id" => _} = user}}, socket, message),
    do: {:noreply, saved(socket, :avatar, user, message)}

  defp avatar_result({:error, {:http, 422, _}} = error, socket, _message),
    do: {:noreply, refused(socket, :avatar, invalid(error, :avatar))}

  defp avatar_result(error, socket, _message),
    do: {:noreply, put_flash(socket, :error, Api.error_message(error))}

  # Language the page will use after a save: the member's choice, else this browser's (`auto`).
  defp locale(socket) do
    case Preferences.of(socket.assigns.current_user)["language"] do
      lang when lang in ~w(en fr) -> lang
      _auto -> socket.assigns[:browser_locale] || "en"
    end
  end

  # Errors of the calls that check the current password and/or a 2FA code: a field message, or a flash.
  # (2FA fields are named `one_time_password`: Phoenix's default parameter filter keeps them out of logs.)
  defp credential_error({:error, {:http, 401, %{"error" => "invalid_code"}}}),
    do:
      {:one_time_password,
       gettext(
         "This code is not valid. Check that your phone's clock is right, then try the newest code."
       )}

  defp credential_error({:error, {:http, 401, _}}),
    do: {:password, gettext("This is not your current password.")}

  defp credential_error({:error, {:http, 429, _}}),
    do:
      {:flash,
       gettext(
         "Too many failed attempts. For your security, please wait 15 minutes before trying again."
       )}

  defp credential_error(error), do: {:flash, Api.error_message(error)}

  defp two_factor_error(socket, form, error) do
    case credential_error(error) do
      {:flash, message} ->
        socket |> assign(two_factor_forms: two_factor_forms()) |> put_flash(:error, message)

      {field, message} ->
        assign(socket, two_factor_forms: two_factor_forms(%{form => [{field, {message, []}}]}))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:settings}
    >
      <div class="space-y-8">
        <.page_header eyebrow={gettext("Your account")} title={gettext("Settings")}>
          <:actions>
            <.link navigate={~p"/account/sanctions"} class="btn btn-ghost" id="account-standing">
              <.icon name="hero-scale" /> {gettext("Account standing")}
            </.link>
          </:actions>
        </.page_header>

        <MysticWeb.PrivacyComponents.deletion_banner user={@current_user} />

        <div class="settings-layout">
          <.settings_nav section={@section} />
          <div id={"settings-#{@section}"} class="min-w-0 max-w-3xl space-y-8">
            <%= case @section do %>
              <% "profile" -> %>
                <.profile_section
                  user={@current_user}
                  form={@profile_form}
                  uploads={@uploads}
                  status={@status}
                  errors={@errors}
                />
              <% "account" -> %>
                <.account_section
                  user={@current_user}
                  email_form={@email_form}
                  email_sent_to={@email_sent_to}
                  password_form={@password_form}
                  dev_hints={@dev_hints}
                />
              <% "security" -> %>
                <MysticWeb.SecurityComponents.two_factor
                  status={@two_factor}
                  setup={@totp_setup}
                  recovery_codes={@recovery_codes}
                  forms={@two_factor_forms}
                />
                <MysticWeb.SecurityComponents.sessions sessions={@sessions} />
              <% "preferences" -> %>
                <.preferences_section
                  preferences={@preferences}
                  time_zone={@time_zone}
                  browser_time_zone={@browser_time_zone}
                  theme_paused={@theme_paused}
                  plan={@plan}
                  entitlements={@entitlements}
                  status={@status}
                  errors={@errors}
                />
              <% "accessibility" -> %>
                <.accessibility_section preferences={@preferences} status={@status} errors={@errors} />
              <% "learning" -> %>
                <.learning_section
                  preferences={@preferences}
                  user={@current_user}
                  status={@status}
                  errors={@errors}
                />
              <% "notifications" -> %>
                <.notifications_section
                  :if={@notification_settings}
                  settings={@notification_settings}
                  preferences={@preferences}
                  time_zone={@time_zone}
                  status={@status}
                  errors={@errors}
                />
              <% "privacy" -> %>
                <.privacy_section
                  :if={@social_settings}
                  settings={@social_settings}
                  status={@status}
                  errors={@errors}
                />
              <% "data" -> %>
                <.export_notice :if={@export_notice} reason={@export_notice} />
                <.data_section
                  user={@current_user}
                  preview={@preview}
                  status={@status}
                  errors={@errors}
                />
                <MysticWeb.PrivacyComponents.your_data
                  user={@current_user}
                  exports={@exports}
                  export_form={@export_form}
                  deletion_form={@deletion_form}
                />
                <.legal_card />
              <% "offline" -> %>
                <MysticWeb.OfflineComponents.settings_section />
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
