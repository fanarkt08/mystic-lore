defmodule MysticWeb.Preferences do
  @moduledoc """
  Applies the member's preferences on every page: language, time zone and `<html>` attributes.
  """
  alias MysticWeb.{Api, Format}
  alias Phoenix.{Component, LiveView}

  @defaults %{
    "language" => "auto",
    "time_zone" => "auto",
    "theme" => "system",
    "reduce_motion" => false,
    "high_contrast" => false,
    "text_size" => 100,
    "underline_links" => false,
    "captions" => true,
    "daily_xp_goal" => 20
  }
  @vip_themes ~w(grove ember parchment)

  def vip_themes, do: @vip_themes

  @doc "Preferences of a member (accounts' private user); defaults for a visitor or missing keys."
  def of(%{"preferences" => %{} = prefs}), do: Map.merge(@defaults, prefs)
  def of(_user), do: @defaults

  def on_mount(:default, _params, session, socket) do
    prefs = of(socket.assigns[:current_user])
    locale = if prefs["language"] in ~w(en fr), do: prefs["language"], else: session["locale"]
    Gettext.put_locale(MysticWeb.Gettext, if(locale in ~w(en fr), do: locale, else: "en"))

    browser_zone =
      if LiveView.connected?(socket), do: (LiveView.get_connect_params(socket) || %{})["tz"]

    socket =
      socket
      |> Component.assign(browser_time_zone: browser_zone, browser_locale: session["locale"])
      |> LiveView.attach_hook(:current_path, :handle_params, &current_path/3)
      |> LiveView.attach_hook(:retry, :handle_event, &retry/3)

    {:cont, apply_preferences(socket, plan(socket.assigns[:current_user], prefs))}
  end

  # Page to come back to after the visitor's language choice (public footer).
  defp current_path(_params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    {:cont, Component.assign(socket, current_path: if(query, do: "#{path}?#{query}", else: path))}
  end

  # « Try again » of an unavailable state (`<.unavailable>`): the same page is mounted again, so every service is
  # really asked again (no cached or made-up data).
  defp retry("ml:retry", _params, socket),
    do:
      {:halt,
       LiveView.push_navigate(socket, to: socket.assigns[:current_path] || "/", replace: true)}

  defp retry(_event, _params, socket), do: {:cont, socket}

  @doc """
  Re-applies the preferences of `@current_user` in an open page (after a save, `{:profile_changed, _}` or
  `{:entitlements_changed, _, plan}`), and pushes the new `<html>` attributes if they changed.
  """
  def refresh(socket, plan \\ :fetch) do
    user = socket.assigns.current_user
    plan = if plan == :fetch, do: plan(user, of(user)), else: plan
    before = socket.assigns[:html_attrs]
    socket = apply_preferences(socket, plan)

    if socket.assigns.html_attrs == before,
      do: socket,
      else:
        LiveView.push_event(socket, "ml:prefs", %{
          attrs: socket.assigns.html_attrs,
          scheme: color_scheme(socket.assigns.theme)
        })
  end

  defp apply_preferences(socket, plan) do
    prefs = of(socket.assigns[:current_user])

    zone =
      if prefs["time_zone"] == "auto",
        do: socket.assigns[:browser_time_zone],
        else: prefs["time_zone"]

    Format.put_time_zone(zone)

    {theme, paused?} =
      cond do
        prefs["theme"] not in @vip_themes -> {prefs["theme"], false}
        plan == "vip" -> {prefs["theme"], false}
        true -> {"system", true}
      end

    Component.assign(socket,
      preferences: prefs,
      theme: theme,
      theme_paused: paused?,
      # paused because billing couldn't confirm the plan (not because the VIP access ended)
      theme_unverified: paused? and is_nil(plan),
      time_zone: Format.time_zone(),
      html_attrs: html_attrs(prefs, theme)
    )
  end

  # The effective plan is asked only for a VIP theme; billing unreachable = not verified = not applied.
  defp plan(%{"id" => id}, %{"theme" => theme}) when theme in @vip_themes do
    case Api.get(nil, :billing, "/api/entitlements/:id", path_params: [id: id]) do
      {:ok, %{"plan" => plan, "status" => status}} when status in ~w(active past_due) -> plan
      # billing answered: no paid plan in effect (ended, canceled…), which is not the same as « unverified »
      {:ok, %{"plan" => _}} -> "free"
      _ -> nil
    end
  end

  defp plan(_user, _prefs), do: nil

  @doc "`data-*` attributes of `<html>` (absent when at their default)."
  def html_attrs(prefs \\ @defaults, theme \\ "system") do
    %{
      "data-theme" => theme,
      "data-motion" => if(prefs["reduce_motion"], do: "reduce"),
      "data-contrast" => if(prefs["high_contrast"], do: "more"),
      "data-text-size" => if(prefs["text_size"] in [112, 125, 150], do: "#{prefs["text_size"]}"),
      "data-links" => if(prefs["underline_links"], do: "underline")
    }
  end

  @doc "Value of `<meta name=\"color-scheme\">` for a theme."
  def color_scheme(theme) when theme in ~w(light parchment), do: "light"
  def color_scheme("system"), do: "light dark"
  def color_scheme(_theme), do: "dark"
end
