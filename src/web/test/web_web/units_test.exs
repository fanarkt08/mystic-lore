defmodule MysticWeb.UnitsTest do
  use ExUnit.Case, async: true

  test "Accept-Language picks the best supported locale" do
    assert MysticWeb.Locale.from_header(["fr-CA,fr;q=0.9,en;q=0.8"]) == "fr"
    assert MysticWeb.Locale.from_header(["de-DE,de;q=0.9,en;q=0.5,fr;q=0.4"]) == "en"
    assert MysticWeb.Locale.from_header(["en;q=0.2, fr;q=0.7"]) == "fr"
    assert MysticWeb.Locale.from_header(["fr;q=0"]) == "en"
    assert MysticWeb.Locale.from_header([]) == "en"
  end

  test "money and dates follow the locale" do
    Gettext.put_locale(MysticWeb.Gettext, "en")
    assert MysticWeb.Format.money(1200, "usd") == "$12"
    assert MysticWeb.Format.money(1250, "usd") == "$12.50"
    assert MysticWeb.Format.date("2026-11-23T10:00:00Z") == "Nov 23, 2026"

    assert MysticWeb.Format.decimal(2.54, 1) == "2.5"
    assert MysticWeb.MessagesComponents.file_size(2_621_440) == "2.5 MB"

    Gettext.put_locale(MysticWeb.Gettext, "fr")
    assert MysticWeb.Format.money(1250, "usd") == "12,50 $ US"
    assert MysticWeb.Format.date("2026-11-23") == "23 nov. 2026"
    assert MysticWeb.Format.decimal(2.54, 1) == "2,5"
    assert MysticWeb.Format.decimal(3, 0) == "3"
    assert MysticWeb.MessagesComponents.file_size(2_621_440) == "2,5 Mo"
  after
    Gettext.put_locale(MysticWeb.Gettext, "en")
  end

  test "a deleted member is named in the page's language, everywhere a name is shown" do
    deleted = %{"username" => "deleted_0123456789abcdef", "display_name" => "Deleted member"}
    lea = %{"username" => "lea", "display_name" => "Léa Moonwhisper"}

    Gettext.put_locale(MysticWeb.Gettext, "fr")
    assert MysticWeb.MysticComponents.member_name(deleted) == "Membre supprimé"
    assert MysticWeb.MysticComponents.member_name(lea) == "Léa Moonwhisper"
    assert MysticWeb.MysticComponents.member_name(%{"username" => "hugo"}) == "hugo"
    assert MysticWeb.MysticComponents.member_name(nil) == nil
    assert MysticWeb.MessagesComponents.name(deleted) == "Membre supprimé"
    assert MysticWeb.MultiplayerComponents.display_name(deleted) == "Membre supprimé"
    assert MysticWeb.Notifications.actor_name(%{"actor" => deleted}) == "Membre supprimé"

    # aperçu d'un groupe : le nom entier, pas « Membre » seul ; un vrai membre garde son prénom
    preview = fn sender ->
      MysticWeb.MessagesComponents.preview(
        %{"kind" => "text", "body" => "Bonsoir", "sender_id" => "s"},
        %{"kind" => "group", "members" => [%{"user" => Map.put(sender, "id", "s")}]},
        "me"
      )
    end

    assert preview.(deleted) =~ "Membre supprimé"
    assert preview.(lea) =~ "Léa"
    refute preview.(lea) =~ "Moonwhisper"

    Gettext.put_locale(MysticWeb.Gettext, "en")
    assert MysticWeb.MysticComponents.member_name(deleted) == "Deleted member"
    refute MysticWeb.MysticComponents.deleted_member?(lea)
  after
    Gettext.put_locale(MysticWeb.Gettext, "en")
  end

  test "rate limiter counts per key and window" do
    key = make_ref()
    assert :ok = Mystic.RateLimiter.hit(:test, key, 2, 60_000)
    assert :ok = Mystic.RateLimiter.hit(:test, key, 2, 60_000)
    assert {:error, seconds} = Mystic.RateLimiter.hit(:test, key, 2, 60_000)
    assert seconds in 1..60
    assert :ok = Mystic.RateLimiter.hit(:test, make_ref(), 2, 60_000)
  end
end
