# Seeds idempotents de learning, avec des données de démo fictives (mix run priv/repo/seeds.exs).
Logger.configure(level: :warning)
import Ecto.Query
alias MlLearning.Repo
alias MlLearning.Catalog.{Adventure, Chapter, Lesson}
alias MlLearning.Gamification.{Badge, Badges, Quest, UserBadge}
alias MlLearning.Progress.{Enrollment, LessonProgress, XpEvent}

now = DateTime.utc_now(:second)
days_ago = fn n -> DateTime.add(now, -n * 86_400) end

upsert = fn schema, attrs, target ->
  Repo.insert!(struct(schema, attrs),
    on_conflict: {:replace_all_except, [:id, :inserted_at]},
    conflict_target: target,
    returning: true
  )
end

# Contenu public + solution (jamais exposée) des nouveaux formats, validés comme à l'import.
video = fn spec ->
  {:ok, content} = MlLearning.Video.validate(spec)
  %{content: content, solution: %{}}
end

simulation = fn content, criterion ->
  {:ok, content, solution} = MlLearning.Sim.validate(content, criterion)
  %{content: content, solution: solution}
end

minigame = fn spec ->
  {:ok, content, solution} = MlLearning.Minigame.build(spec)
  %{content: content, solution: solution}
end

# → {aventure, leçons dans l'ordre de lecture}
seed_adventure = fn attrs, chapters ->
  adventure = upsert.(Adventure, attrs, :slug)

  lessons =
    for {{title, lessons}, c} <- Enum.with_index(chapters, 1),
        chapter =
          upsert.(Chapter, %{adventure_id: adventure.id, position: c, title: title}, [
            :adventure_id,
            :position
          ]),
        {lesson, l} <- Enum.with_index(lessons, 1) do
      upsert.(Lesson, Map.merge(lesson, %{chapter_id: chapter.id, position: l}), [
        :chapter_id,
        :position
      ])
    end

  {adventure, lessons}
end

{forest, forest_lessons} =
  seed_adventure.(
    %{
      slug: "la-foret-des-murmures",
      title: "La Forêt des murmures",
      summary: "Apprenez les boucles de Python en vous occupant d'un bosquet qui murmure.",
      description:
        "Deux chapitres courts dans la forêt. Vous lisez l'histoire du bosquet, vous répondez à un quiz sur le comptage, puis vous écrivez votre première boucle pour arroser trois jeunes arbres.",
      category: "coding",
      difficulty: "beginner",
      premium: false,
      duration_minutes: 25,
      cover: "forest",
      objectives: [
        "Comprendre que range(3) donne 0, 1, 2",
        "Écrire une boucle for qui répète une action",
        "Suivre une boucle pas à pas"
      ],
      prerequisites: ["Aucun, la curiosité suffit"],
      inserted_at: days_ago.(30)
    },
    [
      {"Arrivée au bosquet",
       [
         %{
           title: "Le bosquet se réveille",
           kind: "story",
           xp_reward: 10,
           body:
             "La brume passe entre les chênes. Quelque part, une voix compte à mi-voix : zéro, un, deux… Le bosquet garde ses secrets dans des motifs qui se répètent, et c'est à vous de les apprendre.\n\nUne boucle sert à répéter une instruction sans la réécrire. Vous l'écrivez une fois, et la forêt fait le reste."
         },
         %{
           title: "Compter les plants",
           kind: "exercise",
           xp_reward: 20,
           body: "Le gardien du bosquet vous barre le chemin avec une question sur le comptage.",
           content: %{
             "question" => "Que donne range(3) ?",
             "choices" => ["1, 2, 3", "0, 1, 2", "0, 1, 2, 3", "3, 2, 1"]
           },
           solution: %{
             "answer" => "0, 1, 2",
             "explanation" => "range(3) commence à 0 et s'arrête avant 3 : on obtient 0, 1, 2.",
             "hint" => "Le comptage commence à 0 et s'arrête juste avant le nombre donné."
           }
         }
       ]},
      {"Le bosquet des boucles",
       [
         %{
           title: "Le bosquet des boucles",
           kind: "coding",
           xp_reward: 40,
           body:
             "Trois jeunes arbres attendent en ligne, numérotés 0, 1 et 2. Arrosez chacun une seule fois avec une boucle, plutôt qu'avec trois instructions séparées.",
           content: %{
             "starter" =>
               "# Trois jeunes arbres attendent : 0, 1 et 2.\n# Remplacez cette instruction par une boucle.\nwater(0)\n",
             "hints" => [
               "range(3) donne 0, 1, 2 : exactement les numéros des arbres.",
               "La variable de la boucle peut être passée à water(...).",
               "Écrivez for plant in range(3): puis, à la ligne suivante, water(plant) avec un retrait."
             ],
             "plants" => 3,
             "language_note" =>
               "GroveScript est un tout petit langage, volontairement limité : for nom in range(n): suivi de lignes water(nom) en retrait. Ce n'est pas un vrai interpréteur Python."
           }
         }
       ]}
    ]
  )

{celestial, celestial_lessons} =
  seed_adventure.(
    %{
      slug: "l-atlas-celeste",
      title: "L'Atlas céleste",
      summary: "Repérez les constellations et comprenez pourquoi le ciel tourne pendant la nuit.",
      description:
        "Montez à l'ancien observatoire, ouvrez la coupole et suivez le ciel qui tourne. Vous verrez pourquoi les étoiles semblent tourner autour du pôle, et comment on retrouvait le nord avant la boussole.",
      category: "science",
      difficulty: "intermediate",
      premium: false,
      duration_minutes: 45,
      cover: "observatory",
      objectives: [
        "Expliquer pourquoi les étoiles semblent tourner",
        "Trouver l'étoile Polaire à partir d'une constellation connue"
      ],
      prerequisites: ["Des bases de géométrie"],
      inserted_at: days_ago.(20)
    },
    [
      {"L'observatoire",
       [
         %{
           title: "Ouvrir la coupole",
           kind: "story",
           xp_reward: 15,
           body:
             "La grande coupole s'ouvre en grinçant et l'Atlas se déroule sur la table, avec un petit point d'encre pour chaque étoile. Le gardien tapote la vitre : le ciel ne reste jamais immobile. Si vous regardez assez longtemps, toutes les étoiles glissent vers l'ouest."
         },
         %{
           title: "Pourquoi le ciel tourne",
           kind: "exercise",
           xp_reward: 20,
           body: "Le gardien vous tend une lanterne et vous pose une question.",
           content: %{
             "question" =>
               "Pourquoi les étoiles semblent-elles tourner dans le ciel pendant la nuit ?",
             "choices" => [
               "Les étoiles tournent autour de la Terre chaque nuit",
               "La Terre tourne sur elle-même",
               "La Lune entraîne les étoiles avec elle",
               "Le Soleil les pousse vers l'ouest"
             ]
           },
           solution: %{
             "answer" => "La Terre tourne sur elle-même",
             "explanation" =>
               "La Terre fait un tour sur elle-même chaque jour : tout le ciel semble donc tourner autour des pôles célestes.",
             "hint" =>
               "Demandez-vous ce qui bouge vraiment : le ciel, ou le sol sous le télescope ?"
           }
         }
       ]},
      {"Cartographier la nuit",
       [
         %{
           title: "L'étoile Polaire",
           kind: "story",
           xp_reward: 25,
           body:
             "Suivez les deux étoiles au bord de la Grande Ourse : elles mènent à l'étoile Polaire, qui ne bouge presque pas. Les marins s'en servaient pour trouver le nord bien avant la première boussole."
         }
       ]},
      {"Lire le ciel",
       [
         Map.merge(
           %{
             title: "Lire le ciel de nuit",
             kind: "video",
             xp_reward: 15,
             body:
               "Le gardien baisse les lanternes et lance le vieux film de l'observatoire. Regardez-le avec les sous-titres, ou lisez la transcription : les deux racontent la même chose."
           },
           video.(%{
             "video" => %{
               "src" => "/media/lessons/reading-the-night-sky.webm",
               "type" => "video/webm",
               "poster" => "/media/lessons/reading-the-night-sky.jpg"
             },
             "captions" => [
               %{
                 "lang" => "en",
                 "label" => "English",
                 "src" => "/media/lessons/reading-the-night-sky.en.vtt"
               },
               %{
                 "lang" => "fr",
                 "label" => "Français",
                 "src" => "/media/lessons/reading-the-night-sky.fr.vtt"
               }
             ],
             "duration_s" => 34,
             "transcript" => """
             [Un ciel bleu nuit se remplit d'étoiles. Titre à l'écran : « Lire le ciel de nuit », MysticLore, L'Atlas céleste.]
             Ce soir, nous lisons le ciel nocturne, un repère après l'autre.

             [Des cercles de lumière apparaissent : chaque étoile tourne lentement autour d'un même point.]
             Observez assez longtemps : chaque étoile tourne lentement autour d'un point, le pôle céleste nord.

             [Des traits relient sept étoiles brillantes en forme de casserole, avec l'étiquette « La Grande Ourse ».]
             Sept étoiles brillantes dessinent la Grande Ourse : quatre pour la casserole, trois pour le manche.

             [Les deux étoiles à l'avant de la casserole, Merak et Dubhé, s'allument. Une flèche en pointillé part de Merak et passe par Dubhé.]
             Suivez ses deux étoiles de repère, Merak puis Dubhé, sur environ cinq fois leur écart…

             [La flèche atteint une étoile brillante isolée, avec l'étiquette « Polaris ».]
             …et vous atteignez Polaris, l'étoile polaire, qui bouge à peine de la nuit.

             [Cinq étoiles forment un W, avec l'étiquette « Cassiopée », de l'autre côté de Polaris.]
             De l'autre côté de Polaris, le W de Cassiopée veille.

             [Titre de fin : « Suivez les repères vers le nord ».]
             Trouvez les repères, suivez-les vers le nord, et vous ne perdrez jamais votre chemin.
             """
           })
         ),
         Map.merge(
           %{
             title: "L'étoile errante",
             kind: "simulation",
             xp_reward: 30,
             body:
               "Dans l'Antiquité, on appelait les planètes des « étoiles errantes ». Ici, une jeune planète part à 1 UA de son soleil. Trop lente, elle tombe ; trop rapide, elle s'échappe. Lancez la simulation, lisez le tableau et trouvez une vitesse de départ qui la garde sur une orbite calme et ronde."
           },
           simulation.(
             %{
               "model" => "orbit",
               "goal_text" =>
                 "Gardez la planète sur une orbite fermée, presque circulaire, pendant toute la simulation : elle ne doit ni tomber sur son soleil ni s'échapper.",
               "steps" => 1000,
               "params" => %{
                 "velocity" => %{
                   "min" => 4.0,
                   "max" => 9.0,
                   "step" => 0.1,
                   "default" => 5.0,
                   "label" => "Vitesse de départ",
                   "unit" => "UA/an"
                 },
                 "star_mass" => %{
                   "min" => 0.5,
                   "max" => 2.0,
                   "step" => 0.1,
                   "default" => 1.0,
                   "label" => "Masse du soleil",
                   "unit" => "M☉"
                 }
               },
               "fixed" => %{"distance" => 1.0, "planet_mass" => 0.001, "dt" => 0.002}
             },
             %{"max_eccentricity" => 0.03, "min_revolutions" => 1}
           )
         ),
         Map.merge(
           %{
             title: "Tracer la Grande Ourse",
             kind: "minigame",
             xp_reward: 25,
             body:
               "La page de l'Atlas est vide, à part huit étoiles. Redessinez la Grande Ourse, étoile par étoile."
           },
           minigame.(%{
             "game" => "constellation",
             "prompt" =>
               "Dessinez la Grande Ourse : partez du bout du manche, suivez le manche jusqu'à la casserole, faites le tour de la casserole et refermez-la. Une étoile de la carte ne fait pas partie de la Grande Ourse.",
             "stars" => [
               %{"name" => "Alkaid", "x" => 8, "y" => 62},
               %{"name" => "Mizar", "x" => 24, "y" => 50},
               %{"name" => "Alioth", "x" => 37, "y" => 49},
               %{"name" => "Megrez", "x" => 50, "y" => 52},
               %{"name" => "Phecda", "x" => 52, "y" => 74},
               %{"name" => "Merak", "x" => 76, "y" => 78},
               %{"name" => "Dubhe", "x" => 78, "y" => 52},
               %{"name" => "Polaris", "x" => 90, "y" => 10}
             ],
             "path" => ~w(Alkaid Mizar Alioth Megrez Dubhe Merak Phecda Megrez)
           })
         )
       ]}
    ]
  )

seed_adventure.(
  %{
    slug: "la-machine-de-l-alchimiste",
    title: "La Machine de l'alchimiste",
    summary: "Associez réactions chimiques et engrenages dans un atelier mécanique.",
    description:
      "Redémarrez une vieille machine à vapeur en raisonnant sur la chaleur, la pression et l'équilibre. Chaque cadran que vous tournez montre une cause et son effet.",
    category: "science",
    difficulty: "intermediate",
    premium: true,
    duration_minutes: 90,
    cover: "alchemy",
    objectives: [
      "Équilibrer une réaction simple",
      "Relier une cause et son effet dans un système"
    ],
    prerequisites: ["La Forêt des murmures (conseillé)"],
    inserted_at: days_ago.(10)
  },
  [
    {"L'atelier",
     [
       %{
         title: "Le fourneau froid",
         kind: "story",
         xp_reward: 15,
         body:
           "La machine est froide. Les tuyaux de laiton craquent en refroidissant, et chaque cadran cache une leçon sur l'énergie : rien ne chauffe sans combustible, et rien ne bouge sans chaleur."
       },
       %{
         title: "Équilibrer les vannes",
         kind: "exercise",
         xp_reward: 25,
         body:
           "Deux ampoules de verre sifflent quand les vannes s'ouvrent. La machine ne démarrera que si la réaction est équilibrée.",
         content: %{
           "question" =>
             "Deux volumes d'hydrogène rencontrent un volume d'oxygène. Que produit la machine si la réaction est équilibrée ?",
           "choices" => [
             "Deux volumes d'eau",
             "Un volume d'eau",
             "Trois volumes de vapeur et de fumée",
             "Rien : les gaz s'annulent"
           ]
         },
         solution: %{
           "answer" => "Deux volumes d'eau",
           "explanation" =>
             "2 H2 + O2 donne 2 H2O : les atomes ne sont jamais créés ni détruits, seulement réarrangés.",
           "hint" =>
             "Comptez les atomes de chaque côté : aucun ne doit apparaître ni disparaître."
         }
       }
     ]},
    {"La chambre de réaction",
     [
       Map.merge(
         %{
           title: "Le cœur de la machine",
           kind: "simulation",
           xp_reward: 30,
           body:
             "Le cœur de la machine brûle de l'hydrogène dans de l'oxygène pour faire de la vapeur. À chaque passage dans la chambre, 90 % de ce qui peut encore réagir est transformé. Réglez les coefficients de l'équation, lancez la chambre et regardez le total des atomes : si l'équation est équilibrée, il ne bouge pas."
         },
         simulation.(
           %{
             "model" => "reaction",
             "goal_text" =>
               "Équilibrez H2 + O2 → H2O pour qu'aucun atome ne soit créé ni détruit, avec les plus petits nombres entiers.",
             "steps" => 6,
             "yield_pct" => 90,
             "species" => [
               %{"key" => "h2", "formula" => "H2", "side" => "reactant", "initial" => 10},
               %{"key" => "o2", "formula" => "O2", "side" => "reactant", "initial" => 5},
               %{"key" => "h2o", "formula" => "H2O", "side" => "product", "initial" => 0}
             ],
             "params" => %{
               "h2" => %{
                 "min" => 1,
                 "max" => 8,
                 "step" => 1,
                 "default" => 1,
                 "label" => "Coefficient de H2"
               },
               "o2" => %{
                 "min" => 1,
                 "max" => 8,
                 "step" => 1,
                 "default" => 1,
                 "label" => "Coefficient de O2"
               },
               "h2o" => %{
                 "min" => 1,
                 "max" => 8,
                 "step" => 1,
                 "default" => 1,
                 "label" => "Coefficient de H2O"
               }
             }
           },
           %{"lowest_terms" => true}
         )
       ),
       Map.merge(
         %{
           title: "Redémarrer la vanne",
           kind: "minigame",
           xp_reward: 25,
           body:
             "Le manuel de la machine a perdu sa reliure et les pages de la procédure de redémarrage sont éparpillées sur l'établi."
         },
         minigame.(%{
           "game" => "sequence",
           "prompt" => "Remettez les étapes du redémarrage de la vanne dans un ordre sûr.",
           "items" => [
             "Fermer la sortie de vapeur",
             "Ouvrir l'arrivée de combustible",
             "Allumer le brûleur",
             "Attendre que le manomètre monte",
             "Ouvrir doucement la sortie de vapeur"
           ]
         })
       )
     ]}
  ]
)

seed_adventure.(
  %{
    slug: "les-gardiens-des-archives",
    title: "Les Gardiens des archives",
    summary: "Apprenez à lire des sources, à comparer des témoignages et à bien raconter.",
    description:
      "Les archives gardent mille versions des mêmes événements. Vous apprenez à juger une source, à comparer deux récits d'une même histoire et à citer ce que vous trouvez.",
    category: "humanities",
    difficulty: "beginner",
    premium: false,
    duration_minutes: 60,
    cover: "archive",
    objectives: ["Comparer deux récits d'un même événement", "Citer une source"],
    prerequisites: [],
    inserted_at: days_ago.(5)
  },
  [
    {"La salle de lecture",
     [
       %{
         title: "Poussière et encre",
         kind: "story",
         xp_reward: 10,
         body:
           "Les étagères montent dans le noir. Chaque livre donne la version de quelqu'un, et les archivistes posent la même question à chaque page : qui a écrit ceci, et pourquoi ?"
       },
       %{
         title: "Deux récits",
         kind: "exercise",
         xp_reward: 20,
         body:
           "Deux chroniques sont ouvertes sur le pupitre. Elles parlent de la même crue, mais pas de la même façon.",
         content: %{
           "question" =>
             "Deux chroniques décrivent la même crue de façon différente. Que doit faire un gardien en premier ?",
           "choices" => [
             "Croire la chronique la plus ancienne",
             "Comparer qui a écrit chaque récit, et pourquoi",
             "Garder l'histoire la plus captivante",
             "Écarter les deux récits"
           ]
         },
         solution: %{
           "answer" => "Comparer qui a écrit chaque récit, et pourquoi",
           "explanation" =>
             "Le but et la place de l'auteur influencent ce que dit une source : les comparer est la première étape vers un récit juste.",
           "hint" =>
             "Avant de choisir une histoire, intéressez-vous aux personnes qui l'ont écrite."
         }
       }
     ]},
    {"La chronologie",
     [
       Map.merge(
         %{
           title: "Classer les sources",
           kind: "minigame",
           xp_reward: 25,
           body:
             "Cinq sources sur la même vallée ont été rangées au hasard. Une gardienne commence toujours par dater ce qu'elle lit."
         },
         minigame.(%{
           "game" => "sequence",
           "prompt" =>
             "Classez les sources sur la vallée par ordre chronologique, de la plus ancienne à la plus récente.",
           "items" => [
             "Une tablette d'argile qui recense la récolte (vers 1750 av. J.-C.)",
             "La chronique d'un moine sur la grande crue (1093)",
             "Une brochure imprimée pour les 500 ans de la crue (1593)",
             "L'entretien d'un journal avec le petit-fils d'un rescapé (1893)",
             "La fiche d'un musée dans son catalogue en ligne (2019)"
           ]
         })
       )
     ]}
  ]
)

# --- Activité de lea_moreau : Forêt des murmures terminée (bonus compris), Atlas céleste : 2 leçons sur 6 ---
lea = MlShared.Demo.user("lea_moreau").id
[grove_wakes, rune_quiz, looping_grove] = forest_lessons
[opening_dome, star_quiz | _] = celestial_lessons

completions = [
  {grove_wakes, 4, 1},
  {rune_quiz, 3, 2},
  {looping_grove, 2, 3},
  {opening_dome, 1, 1},
  {star_quiz, 0, 1}
]

for {lesson, ago, attempts} <- completions do
  at = days_ago.(ago)

  Repo.insert_all(
    LessonProgress,
    [
      %{
        id: Ecto.UUID.generate(),
        user_id: lea,
        lesson_id: lesson.id,
        status: "completed",
        attempts: attempts,
        completed_at: at,
        inserted_at: at,
        updated_at: at
      }
    ],
    on_conflict: :nothing,
    conflict_target: [:user_id, :lesson_id]
  )
end

xp_events =
  Enum.map(completions, fn {lesson, ago, _} -> {"lesson:#{lesson.id}", lesson.xp_reward, ago} end) ++
    [{"adventure:#{forest.id}", 50, 2}]

Repo.insert_all(
  XpEvent,
  for {ref_key, amount, ago} <- xp_events do
    %{
      id: Ecto.UUID.generate(),
      user_id: lea,
      ref_key: ref_key,
      amount: amount,
      inserted_at: days_ago.(ago)
    }
  end,
  on_conflict: :nothing,
  conflict_target: [:user_id, :ref_key]
)

Repo.insert_all(
  Enrollment,
  [
    %{
      id: Ecto.UUID.generate(),
      user_id: lea,
      adventure_id: forest.id,
      last_lesson_id: looping_grove.id,
      completed_at: days_ago.(2),
      inserted_at: days_ago.(4),
      updated_at: days_ago.(2)
    },
    %{
      id: Ecto.UUID.generate(),
      user_id: lea,
      adventure_id: celestial.id,
      last_lesson_id: star_quiz.id,
      completed_at: nil,
      inserted_at: days_ago.(1),
      updated_at: now
    }
  ],
  on_conflict: :nothing,
  conflict_target: [:user_id, :adventure_id]
)

# --- Gamification ---
# Le paramètre de « lesson_completed » est le titre exact de la leçon.
badges = [
  {"first-spark", "Première étincelle", "Terminer une première leçon.", "hero-sparkles", "common",
   "lessons_completed", 1, nil},
  {"sprout-tender", "Main verte",
   "Arroser tous les arbres du bosquet des boucles avec une boucle.", "hero-sun", "uncommon",
   "lesson_completed", 1, "Le bosquet des boucles"},
  {"trailblazer", "Bout du chemin", "Terminer une aventure entière.", "hero-flag", "rare",
   "adventures_completed", 1, nil},
  {"hundred-runes", "Cent runes", "Gagner 100 XP.", "hero-star", "common", "total_xp", 100, nil},
  {"five-hundred-runes", "Cinq cents runes", "Gagner 500 XP.", "hero-bolt", "rare", "total_xp",
   500, nil},
  {"apprentice-mage", "Premiers sorts", "Atteindre le niveau 3.", "hero-academic-cap", "uncommon",
   "level", 3, nil},
  {"archmage", "Archimage", "Atteindre le niveau 5.", "hero-trophy", "epic", "level", 5, nil},
  {"ember-keeper", "Braise entretenue", "Apprendre 3 jours de suite.", "hero-fire", "common",
   "streak_days", 3, nil},
  {"moonlit-week", "Semaine au clair de lune", "Apprendre 7 jours de suite.", "hero-moon", "rare",
   "streak_days", 7, nil},
  {"duel-victor", "Première victoire", "Gagner une première partie multijoueur.", "hero-users",
   "uncommon", "multiplayer_wins", 1, nil}
]

for {{slug, name, description, icon, rarity, criterion, target, param}, position} <-
      Enum.with_index(badges, 1) do
  upsert.(
    Badge,
    %{
      slug: slug,
      name: name,
      description: description,
      icon: icon,
      rarity: rarity,
      criterion: criterion,
      target: target,
      param: param,
      position: position
    },
    :slug
  )
end

# {slug, titre, description, type, cible, récompense en XP}
quests = [
  {"daily-lesson", "Terminer une leçon", "Terminez n'importe quelle leçon aujourd'hui.",
   "lessons_completed", 1, 15},
  {"daily-xp", "Gagner 30 XP",
   "Gagnez 30 XP aujourd'hui. Les récompenses des quêtes ne comptent pas.", "xp_earned", 30, 20},
  {"daily-note", "Écrire une note", "Enregistrez une note personnelle sur une leçon aujourd'hui.",
   "note_written", 1, 10}
]

for {{slug, title, description, kind, target, xp_reward}, position} <- Enum.with_index(quests, 1) do
  upsert.(
    Quest,
    %{
      slug: slug,
      title: title,
      description: description,
      kind: kind,
      target: target,
      xp_reward: xp_reward,
      position: position
    },
    :slug
  )
end

for %{id: id} <- MlShared.Demo.users(), do: Badges.award(id)

# Le choix d'un membre n'est jamais écrasé : Léa n'est équipée que si elle n'a aucun badge équipé.
if Badges.equipped(lea) == [] do
  earned =
    Map.new(
      Repo.all(
        from ub in UserBadge,
          join: b in assoc(ub, :badge),
          where: ub.user_id == ^lea,
          select: {b.slug, b.id}
      )
    )

  ids =
    for slug <- ~w(sprout-tender trailblazer ember-keeper),
        Map.has_key?(earned, slug),
        do: earned[slug]

  {:ok, _} = Badges.equip(lea, ids)
end

IO.puts(
  "learning seeds OK — #{Repo.aggregate(Adventure, :count)} adventures, #{Repo.aggregate(Lesson, :count)} lessons, " <>
    "#{Repo.aggregate(Badge, :count)} badges, #{Repo.aggregate(Quest, :count)} daily quests, " <>
    "lea_moreau: #{MlLearning.Progress.dashboard(lea).xp} XP, #{Badges.earned_count(lea)} badges " <>
    "(#{length(Badges.equipped(lea))} equipped)"
)
