defmodule MlLearning.Fixtures do
  @moduledoc "Données de test : aventures (chapitres = listes d'attributs de leçons), badges, quêtes, stubs de billing."
  alias MlLearning.{Catalog, Repo}
  alias MlLearning.Catalog.{Adventure, Chapter, Lesson}
  alias MlLearning.Gamification.{Badge, Quest}
  alias MlLearning.Progress.XpEvent

  def quiz,
    do: %{
      kind: "exercise",
      title: "Rune Quiz",
      content: %{
        "question" => "What does range(3) produce?",
        "choices" => ["1, 2, 3", "0, 1, 2", "3, 2, 1"]
      },
      solution: %{
        "answer" => "0, 1, 2",
        "explanation" => "range(3) starts at 0 and stops before 3.",
        "hint" => "Counting starts at zero."
      },
      xp_reward: 20
    }

  def coding,
    do: %{
      kind: "coding",
      title: "Le bosquet des boucles",
      content: %{"starter" => "water(0)\n"},
      xp_reward: 40
    }

  @doc "Leçon vidéo (chemins servis par web, sous-titres EN, transcription)."
  def video_lesson do
    {:ok, content} =
      MlLearning.Video.validate(%{
        "video" => %{"src" => "/media/lessons/sky.webm", "type" => "video/webm", "poster" => nil},
        "captions" => [
          %{"lang" => "en", "label" => "English", "src" => "/media/lessons/sky.en.vtt"}
        ],
        "transcript" => "Every star turns around the pole.",
        "duration_s" => 30
      })

    %{kind: "video", title: "Lire le ciel de nuit", content: content, xp_reward: 15}
  end

  @doc "Simulation `orbit` : vitesse 4..9 (pas 0,1), masse de l'étoile 0,5..2 ; critère e ≤ 0,03."
  def orbit_lesson do
    {:ok, content, solution} =
      MlLearning.Sim.validate(
        %{
          "model" => "orbit",
          "goal_text" => "Keep the planet on a nearly circular orbit.",
          "steps" => 1000,
          "params" => %{
            "velocity" => %{"min" => 4.0, "max" => 9.0, "step" => 0.1, "default" => 5.0},
            "star_mass" => %{"min" => 0.5, "max" => 2.0, "step" => 0.1, "default" => 1.0}
          },
          "fixed" => %{"distance" => 1.0, "planet_mass" => 0.001, "dt" => 0.002}
        },
        %{"max_eccentricity" => 0.03, "min_revolutions" => 1}
      )

    %{
      kind: "simulation",
      title: "L'étoile errante",
      content: content,
      solution: solution,
      xp_reward: 30
    }
  end

  @doc "Simulation `reaction` : H2 + O2 → H2O, coefficients 1..8, plus petits entiers exigés."
  def reaction_lesson do
    {:ok, content, solution} =
      MlLearning.Sim.validate(
        %{
          "model" => "reaction",
          "goal_text" => "Balance the equation.",
          "steps" => 6,
          "yield_pct" => 90,
          "species" => [
            %{"key" => "h2", "formula" => "H2", "side" => "reactant", "initial" => 10},
            %{"key" => "o2", "formula" => "O2", "side" => "reactant", "initial" => 5},
            %{"key" => "h2o", "formula" => "H2O", "side" => "product", "initial" => 0}
          ],
          "params" =>
            Map.new(~w(h2 o2 h2o), &{&1, %{"min" => 1, "max" => 8, "step" => 1, "default" => 1}})
        },
        %{"lowest_terms" => true}
      )

    %{
      kind: "simulation",
      title: "Le cœur de la machine",
      content: content,
      solution: solution,
      xp_reward: 30
    }
  end

  @doc "Mini-jeu `sequence` (5 étapes, données dans l'ordre attendu)."
  def sequence_lesson do
    {:ok, content, solution} =
      MlLearning.Minigame.build(%{
        "game" => "sequence",
        "prompt" => "Put the steps in a safe order.",
        "items" => [
          "Close the outlet",
          "Open the fuel",
          "Light the burner",
          "Wait",
          "Open the outlet"
        ]
      })

    %{
      kind: "minigame",
      title: "The Brass Valve",
      content: content,
      solution: solution,
      xp_reward: 25
    }
  end

  @doc "Mini-jeu `constellation` (chemin A → B → C → B, D est un leurre)."
  def constellation_lesson do
    {:ok, content, solution} =
      MlLearning.Minigame.build(%{
        "game" => "constellation",
        "prompt" => "Trace the figure.",
        "stars" => [
          %{"name" => "Alpha", "x" => 10, "y" => 10},
          %{"name" => "Beta", "x" => 50, "y" => 40},
          %{"name" => "Gamma", "x" => 90, "y" => 10},
          %{"name" => "Delta", "x" => 50, "y" => 90}
        ],
        "path" => ~w(Alpha Beta Gamma Beta)
      })

    %{
      kind: "minigame",
      title: "The Triangle",
      content: content,
      solution: solution,
      xp_reward: 25
    }
  end

  def adventure_fixture(attrs \\ %{}, chapters \\ [[%{}]]) do
    n = System.unique_integer([:positive])

    defaults = %{
      slug: "adventure-#{n}",
      title: "Adventure #{n}",
      summary: "A short test adventure.",
      category: "coding",
      difficulty: "beginner",
      duration_minutes: 30,
      cover: "forest"
    }

    adventure = Repo.insert!(struct(Adventure, Map.merge(defaults, Map.new(attrs))))

    for {lessons, c} <- Enum.with_index(chapters, 1) do
      chapter =
        Repo.insert!(%Chapter{adventure_id: adventure.id, position: c, title: "Chapter #{c}"})

      for {lesson, l} <- Enum.with_index(lessons, 1) do
        defaults = %{
          chapter_id: chapter.id,
          position: l,
          title: "Lesson #{c}.#{l}",
          kind: "story",
          body: "Once upon a time.",
          xp_reward: 10
        }

        Repo.insert!(struct(Lesson, Map.merge(defaults, Map.new(lesson))))
      end
    end

    Catalog.with_lessons(adventure)
  end

  @doc "Leçons de l'aventure dans l'ordre, prêtes pour les contextes (chapitre et aventure préchargés)."
  def lessons_of(adventure) do
    for lesson <- Catalog.lessons(adventure) do
      {:ok, lesson} = Catalog.fetch_lesson(lesson.id)
      lesson
    end
  end

  def user_id, do: Ecto.UUID.generate()

  @doc "Badge (critère `total_xp` ≥ 1 par défaut), slug unique."
  def badge_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      slug: "badge-#{n}",
      name: "Badge #{n}",
      description: "A test badge.",
      icon: "hero-star",
      rarity: "common",
      criterion: "total_xp",
      target: 1,
      position: n
    }

    Repo.insert!(struct(Badge, Map.merge(defaults, Map.new(attrs))))
  end

  @doc "Quête quotidienne (`lessons_completed` ≥ 1, 15 XP par défaut), slug unique."
  def quest_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      slug: "quest-#{n}",
      title: "Quest #{n}",
      description: "A test quest.",
      kind: "lessons_completed",
      target: 1,
      xp_reward: 15,
      position: n
    }

    Repo.insert!(struct(Quest, Map.merge(defaults, Map.new(attrs))))
  end

  @doc "Événement d'XP daté (UTC)."
  def xp_event(user_id, ref_key, amount, at \\ DateTime.utc_now(:second)),
    do:
      Repo.insert!(%XpEvent{
        user_id: user_id,
        ref_key: ref_key,
        amount: amount,
        inserted_at: DateTime.truncate(at, :second)
      })

  @doc "Installe un faux centre de notifications qui rapporte chaque création au test."
  def stub_center do
    test = self()

    Req.Test.stub(MlShared.Client, fn
      %{request_path: "/api/internal/notifications" <> _} = conn -> center(conn, test)
      conn -> Req.Test.transport_error(conn, :econnrefused)
    end)
  end

  defp center(conn, test) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    send(test, {:center, Jason.decode!(raw)})
    conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"status" => "created"})
  end

  @doc "billing injoignable (le faux centre de notifications répond toujours)."
  def stub_billing_down, do: stub_center()

  @doc "Installe un faux billing qui donne les mêmes droits à tout utilisateur."
  def stub_billing(plan, status \\ "active", period_end \\ nil) do
    test = self()

    Req.Test.stub(MlShared.Client, fn
      %{request_path: "/api/internal/notifications" <> _} = conn ->
        center(conn, test)

      conn ->
        "/api/entitlements/" <> user_id = conn.request_path
        send(test, {:billing_called, user_id})

        Req.Test.json(conn, %{
          "user_id" => user_id,
          "plan" => plan,
          "status" => status,
          "current_period_end" => period_end && DateTime.to_iso8601(period_end),
          "cancel_at_period_end" => false
        })
    end)
  end
end
