# Fictional demo data, idempotent (mix run priv/repo/seeds.exs); the generations match billing's seeded ledger.
alias MlStudio.{Images, Projects, Repo}
alias MlStudio.AI.{Deterministic, Generation}
alias MlStudio.Images.Image
alias MlStudio.Projects.{Collaborator, CourseModule, Lesson, Project, Version}

# En production, seulement pour un déploiement de démo avec un SEED_DEMO_PASSWORD secret.
if Application.get_env(:studio, :env) == :prod and
     MlShared.Demo.password() == "mystic-demo-pass-1",
   do: raise("demo seeds run in production only with a secret SEED_DEMO_PASSWORD")

now = DateTime.utc_now(:second)
ago = fn minutes -> DateTime.add(now, -minutes * 60) end
id = fn prefix, n -> "#{prefix}000000-0000-4000-8000-00000000000#{n}" end

upsert = fn struct, target ->
  Repo.insert!(struct,
    on_conflict: {:replace_all_except, [:id, :inserted_at]},
    conflict_target: target
  )
end

lea = MlShared.Demo.user("lea_moreau").id
ines = MlShared.Demo.user("ines_petit").id
project_id = id.("5a", 1)

upsert.(
  %Project{
    id: project_id,
    owner_id: lea,
    title: "Le Jardin au clair de lune",
    summary:
      "Un jardin qui ne fleurit que sous la lune, pour apprendre comment une boucle répète une instruction.",
    description:
      "Un cours court en deux modules : un récit pour découvrir le jardin, un quiz, puis un exercice GroveScript pour tout arroser avec une seule boucle.",
    objectives: [
      "Expliquer ce que répète une boucle",
      "Lire range(n) comme les nombres de 0 à n-1",
      "Arroser chaque plante avec une seule boucle"
    ],
    prerequisites: ["Aucun, la curiosité suffit"],
    audience: "Débutants curieux, à partir de 10 ans",
    level: "beginner",
    duration_minutes: 25,
    category: "coding",
    cover: "forest",
    status: "draft",
    lock_version: 3,
    content_revision: 7,
    inserted_at: ago.(3 * 24 * 60),
    updated_at: ago.(60)
  },
  :id
)

upsert.(
  %Collaborator{
    id: id.("5f", 1),
    project_id: project_id,
    user_id: ines,
    username: "ines_petit",
    role: "editor",
    invited_by: lea,
    inserted_at: ago.(2 * 24 * 60),
    updated_at: ago.(2 * 24 * 60)
  },
  [:project_id, :user_id]
)

modules = [
  {id.("5b", 1), 1, "Les graines de lune",
   [
     {id.("5c", 1), "story", "La pousse d'argent", 10,
      "À minuit, le jardin se réveille. Une pousse d'argent vous demande de l'eau, puis une autre, puis encore une autre.\n\nUne boucle répète une instruction : vous l'écrivez une fois, et elle arrose toutes les pousses de la rangée.",
      %{}},
     {id.("5c", 2), "exercise", "Compter les pétales", 20,
      "La gardienne du jardin vérifie que vous savez compter avant de vous laisser entrer.",
      %{
        "question" => "Que donne range(3) ?",
        "choices" => ["1, 2, 3", "0, 1, 2", "0, 1, 2, 3"],
        "answer" => 1,
        "explanation" => "range(3) commence à 0 et s'arrête avant 3 : 0, 1 et 2."
      }}
   ]},
  {id.("5b", 2), 2, "Les plates-bandes",
   [
     {id.("5c", 3), "coding", "Arroser les saules", 40,
      "Quatre saules attendent en ligne, numérotés de 0 à 3. Arrosez chacun une seule fois, avec une boucle.",
      %{
        "plants" => 4,
        "starter" => "# Quatre saules : 0, 1, 2 et 3.\nwater(0)\n",
        "hints" => [
          "range(4) donne 0, 1, 2 et 3.",
          "Passez la variable de la boucle à water(...)."
        ]
      }},
     {id.("5c", 4), "story", "La floraison", 10,
      "Chaque saule a bu, et tout le jardin fleurit en même temps. Une boucle, quatre fleurs.",
      %{}}
   ]}
]

for {module_id, position, title, lessons} <- modules do
  upsert.(
    %CourseModule{
      id: module_id,
      project_id: project_id,
      position: position,
      title: title,
      inserted_at: ago.(2000),
      updated_at: ago.(90)
    },
    :id
  )

  for {{lesson_id, kind, lesson_title, xp, body, content}, j} <- Enum.with_index(lessons, 1) do
    upsert.(
      %Lesson{
        id: lesson_id,
        project_id: project_id,
        module_id: module_id,
        position: j,
        title: lesson_title,
        kind: kind,
        body: body,
        xp_reward: xp,
        content: content,
        inserted_at: ago.(2000),
        updated_at: ago.(90)
      },
      :id
    )
  end
end

# ines's DEMO image (VIP), with its text alternative
image_id = id.("5e", 1)
svg = Deterministic.svg("Feuilles de saule en spirale")

image =
  upsert.(
    %Image{
      id: image_id,
      project_id: project_id,
      lesson_id: id.("5c", 4),
      uploader_id: ines,
      alt: "Feuilles de saule disposées en spirale (motif de démonstration)",
      content_type: "image/svg+xml",
      byte_size: byte_size(svg),
      source: "demo",
      inserted_at: ago.(90),
      updated_at: ago.(85)
    },
    :id
  )

File.mkdir_p!(Path.dirname(Images.path(image)))
File.write!(Images.path(image), svg)

# Two immutable versions (never rewritten: insert only when missing)
project = Projects.load(Repo.get!(Project, project_id))
full = Projects.snapshot(project)
first = %{full | "modules" => Enum.take(full["modules"], 1), "images" => []}

for {n, note, snapshot, minutes} <- [
      {1, "Premier plan", first, 2 * 24 * 60},
      {2, "Ajout des plates-bandes", full, 120}
    ] do
  Repo.insert!(
    %Version{
      id: id.("51", n),
      project_id: project_id,
      number: n,
      note: note,
      source: "manual",
      author_id: lea,
      snapshot: snapshot,
      inserted_at: ago.(minutes)
    },
    on_conflict: :nothing,
    conflict_target: [:project_id, :number]
  )
end

# AI history (refs "studio:gen:<id>" seeded in billing's credit ledger)
generations = [
  {1, lea, "outline", nil, "succeeded", 2, "consumed",
   "Un cours tranquille sur les boucles dans un jardin au clair de lune",
   %{"modules" => [%{"title" => "Module de démo 1 : Les graines de lune", "lessons" => []}]}, nil,
   240},
  {2, lea, "lesson_draft", id.("5c", 3), "succeeded", 5, "consumed",
   "Un exercice avec quatre saules",
   %{
     "body" => "DEMO MODE — not a real AI.",
     "content" => %{"plants" => 4, "starter" => "water(0)\n", "hints" => []}
   }, nil, 180},
  {3, lea, "lesson_draft", id.("5c", 4), "failed", 5, "released", "Le jardin fleurit", nil,
   "provider_unavailable", 120},
  {4, ines, "image", id.("5c", 4), "succeeded", 12, "consumed", "Feuilles de saule en spirale",
   %{"image_id" => image_id}, nil, 90}
]

for {n, user, kind, lesson_id, status, cost, credits, brief, result, error, minutes} <-
      generations do
  upsert.(
    %Generation{
      id: id.("5d", n),
      project_id: project_id,
      lesson_id: lesson_id,
      user_id: user,
      kind: kind,
      status: status,
      cost: cost,
      provider: "demo",
      brief: brief,
      result: result,
      error: error,
      credits: credits,
      applied_at: if(status == "succeeded" and kind != "image", do: ago.(minutes - 2)),
      started_at: ago.(minutes),
      finished_at: ago.(minutes - 1),
      inserted_at: ago.(minutes),
      updated_at: ago.(minutes - 1)
    },
    :id
  )
end

IO.puts(
  "studio seeds: « Le Jardin au clair de lune » (lea + ines editor), 2 modules, 4 lessons, 2 versions, 1 image, 4 AI generations"
)
