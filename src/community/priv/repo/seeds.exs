# Seeds de community : discussions, réponses, votes et un signalement de démo, fictifs et idempotents
# (mix run priv/repo/seeds.exs).
import Ecto.Query
alias MlCommunity.{Discussion, Follow, Reply, Reports, Repo, Viewer, Votes}

ids = Map.new(MlShared.Demo.users(), &{&1.username, &1.id})
now = DateTime.utc_now()
ago = fn hours -> DateTime.add(now, -round(hours * 3600), :second) end

# Slug stable d'un seed : titre + suffixe déterministe (au lieu du suffixe aléatoire des vraies créations).
slug = fn title ->
  suffix = :sha256 |> :crypto.hash(title) |> Base.encode32(case: :lower) |> binary_part(0, 8)
  Discussion.slugify(title) <> "-" <> suffix
end

discussion = fn category, author, title, body, hours, opts ->
  Repo.get_by(Discussion, slug: slug.(title)) ||
    Repo.insert!(%Discussion{
      category: category,
      author_id: ids[author],
      title: title,
      slug: slug.(title),
      body: body,
      pinned: Keyword.get(opts, :pinned, false),
      last_activity_at: ago.(hours),
      inserted_at: ago.(hours),
      updated_at: ago.(hours)
    })
end

reply = fn d, author, body, hours ->
  reply =
    Repo.one(from r in Reply, where: r.discussion_id == ^d.id and r.body == ^body) ||
      Repo.insert!(%Reply{
        discussion_id: d.id,
        author_id: ids[author],
        body: body,
        inserted_at: ago.(hours),
        updated_at: ago.(hours)
      })

  Repo.update_all(
    from(x in Discussion, where: x.id == ^d.id and x.last_activity_at < ^reply.inserted_at),
    set: [last_activity_at: reply.inserted_at]
  )

  reply
end

follow = fn username, d ->
  Repo.insert_all(Follow, [%{user_id: ids[username], discussion_id: d.id, inserted_at: now}],
    on_conflict: :nothing
  )
end

viewer = fn username -> %Viewer{id: ids[username]} end

welcome =
  discussion.(
    "announcements",
    "clara_dubois",
    "Bienvenue sur le forum de MysticLore",
    """
    Bonjour à toutes et à tous ! Ici, vous pouvez poser vos questions, partager vos cartes du ciel ou vos expériences, et trouver des personnes avec qui réviser.

    Trois règles simples : restez bienveillants, restez dans le sujet et signalez ce qui pose problème. Les modérateurs lisent chaque signalement.
    Règles complètes (lien de démonstration) : https://example.com/mysticlore/forum-guidelines
    """,
    120,
    pinned: true
  )

range =
  discussion.(
    "help-questions",
    "hugo_bernard",
    "Pourquoi range(3) s'arrête à 2 dans la Forêt des murmures ?",
    "Je pensais que le troisième arbre aurait le numéro 3, mais la boucle arrose 0, 1 et 2. Le bosquet a un bug, ou il y a quelque chose que je n'ai pas compris ?",
    30,
    []
  )

atlas =
  discussion.(
    "showcase",
    "lea_moreau",
    "Ma première carte du ciel avec l'Atlas céleste",
    "J'ai fini le premier chapitre et j'ai dessiné la ceinture d'Orion à la main. Je partage mes notes, si vous voulez comparer avec vos cartes.",
    20,
    []
  )

engine =
  discussion.(
    "study-groups",
    "ines_petit",
    "Groupe de travail pour La Machine de l'alchimiste (en semaine, le soir)",
    "Je cherche deux ou trois personnes pour faire ensemble le chapitre sur les vannes. On pourrait mettre nos notes en commun le mercredi soir.",
    12,
    []
  )

archive =
  discussion.(
    "off-topic",
    "sarah_lefevre",
    "Votre coin lecture préféré dans les archives ?",
    "Le mien, c'est la table près de la fenêtre est, quand la poussière devient dorée vers 16 h. Et vous, vous lisez où ?",
    6,
    []
  )

backwards =
  discussion.(
    "help-questions",
    "ines_petit",
    "Peut-on arroser les arbres à l'envers avec une boucle ?",
    "Est-ce qu'on peut compter de 2 à 0 dans le langage du bosquet ? Je n'ai pas encore trouvé, quelqu'un a déjà essayé ?",
    3,
    []
  )

answer =
  reply.(
    range,
    "lea_moreau",
    "Ce n'est pas un bug : range(3) commence à 0 et s'arrête avant 3, donc on obtient 0, 1 et 2. Ça fait bien trois arbres.",
    28
  )

tip =
  reply.(
    range,
    "theo_garnier",
    "Astuce : lisez-le comme « trois pas, en partant de zéro ». On s'y fait vite.",
    27
  )

reply.(
  range,
  "hugo_bernard",
  "Ah d'accord, merci à vous deux ! Le quiz dit la même chose.",
  26
)

reply.(
  atlas,
  "hugo_bernard",
  "Très jolie carte ! Tu as utilisé le calque des saisons de la deuxième leçon ?",
  18
)

reply.(atlas, "sarah_lefevre", "Je garde ça pour mes notes, merci du partage.", 17)
reply.(engine, "lea_moreau", "Je suis partante pour le mercredi !", 10)

reply.(
  archive,
  "theo_garnier",
  "Le petit coin lecture sous l'escalier de l'observatoire. Personne ne le trouve jamais.",
  5
)

offtopic =
  reply.(
    archive,
    "hugo_bernard",
    "Premier ! Sinon, qui veut échanger des pierres runiques ? Écrivez-moi.",
    4
  )

# Solution choisie par l'auteur de la question.
Repo.update_all(from(d in Discussion, where: d.id == ^range.id),
  set: [solution_reply_id: answer.id]
)

# Votes « utile » par les règles réelles (idempotents, compteurs tenus dans la même transaction).
for {username, target} <- [
      {"hugo_bernard", answer},
      {"ines_petit", answer},
      {"sarah_lefevre", answer},
      {"lea_moreau", tip},
      {"hugo_bernard", atlas},
      {"sarah_lefevre", atlas},
      {"lea_moreau", welcome}
    ] do
  {:ok, _} = Votes.set(viewer.(username), Repo.reload!(target), true)
end

# Suivis : chaque auteur suit sa discussion, chaque membre qui a répondu aussi (comme en vrai).
for {username, d} <- [
      {"clara_dubois", welcome},
      {"hugo_bernard", range},
      {"lea_moreau", range},
      {"theo_garnier", range},
      {"lea_moreau", atlas},
      {"hugo_bernard", atlas},
      {"sarah_lefevre", atlas},
      {"ines_petit", engine},
      {"lea_moreau", engine},
      {"sarah_lefevre", archive},
      {"theo_garnier", archive},
      {"hugo_bernard", archive},
      {"ines_petit", backwards}
    ],
    do: follow.(username, d)

# Un signalement ouvert (un seul par rapporteur et cible : relancer les seeds n'en crée pas d'autre).
case Reports.create(viewer.("lea_moreau"), %{
       "target_type" => "reply",
       "target_id" => offtopic.id,
       "reason" => "spam",
       "details" => "Signalement de démonstration : proposition d'échange hors sujet."
     }) do
  {:ok, _report} -> :ok
  {:error, :already_reported} -> :ok
end

IO.puts("community seeds: ok")
