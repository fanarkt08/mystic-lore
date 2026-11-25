# Membres de démo fictifs (UUID fixes de `MlShared.Demo`), idempotents : mix run priv/repo/seeds.exs
alias MlAccounts.{Preferences, Repo, User}

# Jamais le mot de passe de démo en production, ni dans une release (sans Mix, elle compte comme production) :
# il faut alors un SEED_DEMO_PASSWORD secret d'au moins 16 caractères.
production? = not Code.ensure_loaded?(Mix) or Mix.env() == :prod
demo_password = MlShared.Demo.password()

if production? and (demo_password == "mystic-demo-pass-1" or String.length(demo_password) < 16),
  do:
    raise(
      "Demo members are seeded in production only with a secret SEED_DEMO_PASSWORD (16+ characters)"
    )

bios = %{
  "lea_moreau" =>
    "Je révise le soir, souvent avec une carte du ciel ouverte à côté. En ce moment : les boucles en Python.",
  "hugo_bernard" => "Astronome amateur. J'apprends à coder petit à petit, une leçon à la fois.",
  "ines_petit" =>
    "J'aime mettre de l'ordre dans les données. Je suis surtout le parcours de chimie.",
  "sarah_lefevre" => "Les vieilles cartes, les mots oubliés et les bonnes questions.",
  "theo_garnier" => "Modérateur du forum. Bienveillant, mais ferme sur les règles.",
  "clara_dubois" => "J'administre MysticLore et je réponds aux demandes de support."
}

profiles = %{
  "lea_moreau" => %{
    pronouns: "elle",
    interests: ~w(astronomy botany coding),
    cover: "observatory",
    profile_visibility: "public",
    avatar_crest: "moon"
  },
  "ines_petit" => %{
    interests: ~w(alchemy mathematics),
    cover: "alchemy",
    avatar_crest: "flame",
    preferences: %Preferences{theme: "grove"}
  },
  "sarah_lefevre" => %{
    pronouns: "elle",
    interests: ~w(history languages),
    cover: "archive",
    profile_visibility: "friends"
  }
}

defaults = %{
  pronouns: nil,
  interests: [],
  cover: nil,
  profile_visibility: "members",
  avatar_crest: nil,
  avatar_image: nil,
  preferences: %Preferences{}
}

now = DateTime.utc_now(:second)

# Les membres de démo ont terminé l'accueil guidé : les parcours existants ne passent pas par /welcome.
replaced =
  [
    :email,
    :username,
    :display_name,
    :bio,
    :role,
    :hashed_password,
    :confirmed_at,
    :onboarding_status,
    :onboarding_at,
    :updated_at
  ] ++
    Map.keys(defaults)

for {demo, i} <- Enum.with_index(MlShared.Demo.users()) do
  joined = DateTime.add(now, -(120 - 15 * i), :day)
  profile = Map.merge(defaults, Map.get(profiles, demo.username, %{}))

  Repo.insert!(
    struct!(
      %User{
        id: demo.id,
        email: demo.email,
        username: demo.username,
        display_name: demo.display_name,
        bio: Map.fetch!(bios, demo.username),
        role: demo.role,
        hashed_password: Bcrypt.hash_pwd_salt(MlShared.Demo.password()),
        confirmed_at: joined,
        onboarding_status: "completed",
        onboarding_at: joined,
        inserted_at: joined,
        updated_at: now
      },
      profile
    ),
    on_conflict: {:replace, replaced},
    conflict_target: :id
  )
end

IO.puts("accounts: #{length(MlShared.Demo.users())} demo members seeded")
