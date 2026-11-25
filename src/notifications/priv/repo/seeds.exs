# Seeds du centre de notifications : notifications et réglages de démo fictifs, idempotents
# (mix run priv/repo/seeds.exs).
import Ecto.Query
alias MlNotifications.{Notification, Repo, Setting}

[lea, hugo, ines, sarah, theo] =
  Enum.map(
    ~w(lea_moreau hugo_bernard ines_petit sarah_lefevre theo_garnier),
    &MlShared.Demo.user(&1).id
  )

now = DateTime.utc_now()
ago = fn minutes -> DateTime.add(now, -minutes * 60, :second) end

# Slug stable d'une discussion seedée par community (titre + suffixe déterministe).
discussion = fn title ->
  suffix = :sha256 |> :crypto.hash(title) |> Base.encode32(case: :lower) |> binary_part(0, 8)

  base =
    title
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[^\x00-\x7F]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
    |> String.trim("-")

  %{"slug" => base <> "-" <> suffix, "title" => title}
end

range = discussion.("Pourquoi range(3) s'arrête à 2 dans la Forêt des murmures ?")
atlas = discussion.("Ma première carte du ciel avec l'Atlas céleste")
archive = discussion.("Votre coin lecture préféré dans les archives ?")

seed = fn user, key, attrs ->
  key = "seed:" <> key

  unless Repo.exists?(from n in Notification, where: n.user_id == ^user and n.dedupe_key == ^key) do
    at = ago.(attrs.minutes)

    Repo.insert!(%Notification{
      user_id: user,
      category: attrs.category,
      kind: attrs.kind,
      actor_id: attrs[:actor],
      subject_type: attrs[:subject] && elem(attrs.subject, 0),
      subject_id: attrs[:subject] && elem(attrs.subject, 1),
      params: attrs[:params] || %{},
      dedupe_key: key,
      count: attrs[:count] || 1,
      read_at: if(attrs[:read], do: DateTime.add(at, 600, :second)),
      last_event_at: at,
      inserted_at: at,
      updated_at: at
    })
  end
end

seed.(lea, "sarah-request", %{
  category: "friends",
  kind: "friend_request_received",
  actor: sarah,
  subject: {"member", sarah},
  minutes: 50
})

seed.(lea, "range-reply", %{
  category: "community",
  kind: "community_reply",
  actor: hugo,
  subject: {"discussion", range["slug"]},
  params: range,
  minutes: 95
})

seed.(lea, "atlas-replies", %{
  category: "community",
  kind: "community_reply",
  actor: sarah,
  subject: {"discussion", atlas["slug"]},
  params: atlas,
  count: 2,
  read: true,
  minutes: 600
})

seed.(lea, "first-spark", %{
  category: "learning",
  kind: "badge_earned",
  subject: {"badge", "first-spark"},
  params: %{"badge_slug" => "first-spark", "badge_name" => "Première étincelle"},
  read: true,
  minutes: 2 * 24 * 60
})

seed.(lea, "premium", %{
  category: "billing",
  kind: "subscription_activated",
  subject: {"plan", "premium"},
  params: %{"plan" => "premium"},
  read: true,
  minutes: 5 * 24 * 60
})

seed.(hugo, "lea-accepted", %{
  category: "friends",
  kind: "friend_request_accepted",
  actor: lea,
  subject: {"member", lea},
  read: true,
  minutes: 4 * 24 * 60
})

seed.(hugo, "range-reply", %{
  category: "community",
  kind: "community_reply",
  actor: lea,
  subject: {"discussion", range["slug"]},
  params: range,
  minutes: 120
})

seed.(hugo, "archive-reply", %{
  category: "community",
  kind: "community_reply",
  actor: theo,
  subject: {"discussion", archive["slug"]},
  params: archive,
  read: true,
  minutes: 5 * 60
})

unless Repo.get(Setting, ines) do
  Repo.insert!(%Setting{
    user_id: ines,
    quiet_enabled: true,
    quiet_start: ~T[22:00:00],
    quiet_end: ~T[07:00:00],
    time_zone: "Europe/Paris"
  })
end

IO.puts("notifications: demo notifications for Léa and Hugo, quiet hours for Inès")
