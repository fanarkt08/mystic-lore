defmodule MysticWeb.Preferences.ContrastTest do
  @moduledoc """
  WCAG AA (texte ≥ 4,5:1), calculé sur les jetons de couleur de chaque thème : le sombre de base (`@theme` de
  app.css) et ceux de features/preferences.css (clair, VIP). Toute modification d'un jeton repasse ce calcul.
  """
  use ExUnit.Case, async: true

  @css Path.expand("../../../assets/css", __DIR__)
  @texts ~w(ink prose muted magic info reward success danger)
  @backgrounds ~w(canvas surface raised sunken)
  # textes posés sur une couleur pleine : boutons, bulles, pastilles, initiales des avatars
  @solid [
    {"white", "action"},
    {"white", "action-hover"},
    {"canvas", "reward"},
    {"canvas", "reward-hover"},
    {"canvas", "magic"},
    {"canvas", "info"},
    {"canvas", "success"}
  ]

  defp tokens(block),
    do:
      for(
        [_, name, hex] <- Regex.scan(~r/--color-([a-z-]+):\s*#([0-9a-fA-F]{6});/, block),
        into: %{},
        do: {name, hex}
      )

  defp themes do
    app = File.read!(Path.join(@css, "app.css"))
    prefs = File.read!(Path.join(@css, "features/preferences.css"))
    [_, base] = Regex.run(~r/@theme \{(.*?)\n\}/s, app)

    named =
      for [_, name, block] <- Regex.scan(~r/html\[data-theme="(\w+)"\] \{(.*?)\}/s, prefs),
          block =~ "--color-canvas",
          into: %{},
          do: {name, tokens(block)}

    Map.put(named, "dark", tokens(base))
  end

  defp luminance(hex) do
    <<r::8, g::8, b::8>> = Base.decode16!(hex, case: :mixed)

    [r, g, b]
    |> Enum.map(fn c ->
      c = c / 255
      if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
    end)
    |> then(fn [r, g, b] -> 0.2126 * r + 0.7152 * g + 0.0722 * b end)
  end

  defp ratio(a, b) do
    [light, dark] = Enum.sort([luminance(a), luminance(b)], :desc)
    (light + 0.05) / (dark + 0.05)
  end

  test "every theme defines every token and passes AA for text on all its surfaces" do
    themes = themes()
    assert Enum.sort(Map.keys(themes)) == ~w(dark ember grove light parchment system)

    required =
      MapSet.new(
        @texts ++ @backgrounds ++ ~w(white action action-hover reward-hover line line-strong)
      )

    failures =
      for {theme, colors} <- themes,
          missing = MapSet.difference(required, MapSet.new(Map.keys(colors))),
          pair <-
            if(MapSet.size(missing) > 0, do: [{:missing, MapSet.to_list(missing)}], else: pairs()),
          failure = check(colors, pair),
          do: {theme, failure}

    assert failures == []
  end

  test "the system theme in light mode is exactly the light theme" do
    themes = themes()
    assert themes["system"] == themes["light"]
  end

  test "the high-contrast mode keeps secondary text at the level of the main text" do
    prefs = File.read!(Path.join(@css, "features/preferences.css"))
    [_, block] = Regex.run(~r/html\[data-contrast="more"\] \{(.*?)\}/s, prefs)
    assert block =~ "--color-muted: var(--color-ink);"
    assert block =~ "--color-prose: var(--color-ink);"
  end

  defp pairs, do: for(fg <- @texts, bg <- @backgrounds, do: {fg, bg}) ++ @solid

  defp check(_colors, {:missing, names}), do: {:missing, names}

  defp check(colors, {fg, bg}) do
    value = ratio(colors[fg], colors[bg])
    if value < 4.5, do: {fg, bg, Float.round(value, 2)}
  end
end
