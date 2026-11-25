defmodule MlStudio.FormatsTest do
  @moduledoc "Studio side of the video, simulation and mini-game lessons: content, media, checks, import, AI."
  use MlStudio.DataCase, async: true
  alias MlStudio.{AI, Media, Projects, Publishing, WebVTT}
  alias MlStudio.Media.Medium
  alias MlStudio.Projects.{Lesson, Project}
  alias MlStudio.Publishing.{Checks, ImportWorker}

  @theo "00000000-0000-4000-8000-000000000005"
  @vtt "WEBVTT\n\n00:00.500 --> 00:04.000\nTonight we read the sky.\n\n1\n00:04.000 --> 00:08.000\n<i>Find</i> the pointers.\n"

  setup do
    owner = uuid()
    project = project_fixture(owner)
    module = hd(Projects.load(project).modules)
    {:ok, owner: owner, project: project, module: module}
  end

  defp webm,
    do:
      <<0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81, 0x01, "B", 0x82, 0x84, "webm">> <>
        :crypto.strong_rand_bytes(256)

  defp mp4, do: <<0, 0, 0, 24, "ftypisom">> <> :crypto.strong_rand_bytes(256)

  defp add(owner, project, module, kind, title, attrs \\ %{}),
    do: lesson!(owner, project, module, kind, title, attrs)

  defp codes(project, key) do
    project
    |> Projects.load()
    |> Projects.snapshot()
    |> Checks.run()
    |> Enum.find(&(&1["key"] == key))
    |> Map.fetch!("issues")
    |> Enum.map(& &1["code"])
  end

  # a complete, publishable video lesson
  defp video_lesson(owner, project, module) do
    lesson =
      add(owner, project, module, "video", "Lire le ciel de nuit", %{
        "body" => "Watch the star-film.",
        "content" => %{"transcript" => "Tonight we read the sky.", "duration_s" => 34}
      })

    {:ok, _} = Media.upload_video(owner, project.id, lesson.id, webm())

    {:ok, %{lesson: lesson}} =
      Media.add_captions(owner, project.id, lesson.id, %{
        "lang" => "en",
        "label" => "English",
        "vtt" => @vtt
      })

    lesson
  end

  describe "lesson content" do
    test "new lessons start with editable defaults; an autosave never changes the media", %{
      owner: owner,
      project: p,
      module: m
    } do
      sim = add(owner, p, m, "simulation", "Orbit lab")
      assert %{"model" => "orbit", "steps" => 1000, "velocity" => %{"min" => 4}} = sim.content
      game = add(owner, p, m, "minigame", "Sort it")
      assert %{"game" => "sequence", "items" => [], "stars" => []} = game.content
      video = add(owner, p, m, "video", "Film")
      assert %{"video_id" => nil, "captions" => [], "transcript" => ""} = video.content

      forged = Ecto.UUID.generate()

      assert {:ok, %Lesson{content: %{"video_id" => nil, "transcript" => "Hello"}}} =
               Projects.update_lesson(owner, p.id, video.id, %{
                 "lock_version" => video.lock_version,
                 "content" => %{"video_id" => forged, "transcript" => "Hello"}
               })

      assert {:error, %Ecto.Changeset{}} =
               Projects.update_lesson(owner, p.id, sim.id, %{
                 "lock_version" => sim.lock_version,
                 "content" => %{"model" => "fusion"}
               })
    end
  end

  describe "media" do
    test "videos are recognised by signature (WebM, MP4), ≤ 50 MB, on video lessons only", %{
      owner: owner,
      project: p,
      module: m
    } do
      video = add(owner, p, m, "video", "Film")
      story = hd(Projects.load(p).modules |> hd() |> Map.fetch!(:lessons))

      for bad <- ["", "not a video", png(), <<0x1A, 0x45, 0xDF, 0xA3, "matroska">>] do
        assert {:error, {:invalid, %{data: _}}} = Media.upload_video(owner, p.id, video.id, bad)
      end

      assert {:error, {:invalid, %{data: ["must be at most 50 MB"]}}} =
               Media.sniff(webm() <> :binary.copy(<<0>>, Media.max_video_bytes()))

      assert {:error, {:invalid, %{lesson_id: _}}} =
               Media.upload_video(owner, p.id, story.id, webm())

      assert {:ok, %{medium: first, lesson: %{content: %{"video_id" => first_id}}}} =
               Media.upload_video(owner, p.id, video.id, webm())

      assert first.content_type == "video/webm" and first.id == first_id
      assert {:ok, ^first, path} = Media.fetch(owner, p.id, first.id)
      assert File.exists?(path)

      # a new upload replaces the video (the old file is removed: it was never published)
      assert {:ok, %{medium: %{content_type: "video/mp4"} = second}} =
               Media.upload_video(owner, p.id, video.id, mp4())

      refute Repo.get(Medium, first.id)
      refute File.exists?(path)
      assert Repo.get!(Lesson, video.id).content["video_id"] == second.id

      # a stranger never gets the file
      assert {:error, :not_found} = Media.fetch(uuid(), p.id, second.id)
    end

    test "caption tracks: strict WebVTT, one per language, removable", %{
      owner: owner,
      project: p,
      module: m
    } do
      video = add(owner, p, m, "video", "Film")
      add = fn params -> Media.add_captions(owner, p.id, video.id, params) end
      base = %{"lang" => "en", "label" => "English", "vtt" => @vtt}

      for {params, field} <- [
            {%{base | "vtt" => "Tonight we read the sky."}, :vtt},
            {%{base | "vtt" => "WEBVTT\n\n00:05.000 --> 00:01.000\nBackwards"}, :vtt},
            {%{
               base
               | "vtt" =>
                   "WEBVTT\n\nSTYLE\n::cue { background: url(http://x) }\n\n00:01.000 --> 00:02.000\nHi"
             }, :vtt},
            {%{base | "vtt" => "WEBVTT\n\n00:01.000 --> 00:02.000\n<script>alert(1)</script>"},
             :vtt},
            {%{base | "vtt" => "WEBVTT\n\nNOTE only a note"}, :vtt},
            {%{base | "lang" => "english"}, :lang},
            {%{base | "label" => " "}, :label}
          ] do
        assert {:error, {:invalid, errors}} = add.(params)
        assert Map.has_key?(errors, field), inspect(params)
      end

      assert {:ok, 2} = WebVTT.validate(@vtt)
      assert {:ok, %{medium: en}} = add.(base)
      assert {:ok, %{medium: _fr}} = add.(%{base | "lang" => "fr", "label" => "Français"})
      assert {:ok, %{medium: en2, lesson: lesson}} = add.(%{base | "label" => "English (US)"})
      refute Repo.get(Medium, en.id)
      assert [%{"lang" => "fr"}, %{"lang" => "en", "media_id" => id}] = lesson.content["captions"]
      assert id == en2.id

      assert {:ok, :deleted} = Media.delete_captions(owner, p.id, video.id, "fr")
      assert {:error, :not_found} = Media.delete_captions(owner, p.id, video.id, "fr")
      assert [%{"lang" => "en"}] = Repo.get!(Lesson, video.id).content["captions"]
    end
  end

  describe "publication checks" do
    test "a video without captions or transcript blocks the submission", %{
      owner: owner,
      project: p,
      module: m
    } do
      video = add(owner, p, m, "video", "Film", %{"body" => "Watch."})
      assert codes(p, "videos") == ~w(video_file video_captions video_transcript video_duration)

      assert {:error, {:checks_failed, checks}} =
               p |> attested() |> then(&Publishing.submit(owner, &1.id))

      assert %{"ok" => false} = Enum.find(checks, &(&1["key"] == "videos"))

      {:ok, _} = Media.upload_video(owner, p.id, video.id, webm())

      {:ok, _} =
        Media.add_captions(owner, p.id, video.id, %{
          "lang" => "en",
          "label" => "English",
          "vtt" => @vtt
        })

      assert codes(p, "videos") == ~w(video_transcript video_duration)
      video = Repo.get!(Lesson, video.id)

      {:ok, _} =
        Projects.update_lesson(owner, p.id, video.id, %{
          "lock_version" => video.lock_version,
          "content" => %{"transcript" => "Tonight we read the sky.", "duration_s" => 34}
        })

      assert codes(p, "videos") == []

      assert {:ok, %Project{status: "submitted"}} =
               p |> attested() |> then(&Publishing.submit(owner, &1.id))
    end

    test "simulations: allowed model, bounds inside the engine limits, objective", %{
      owner: owner,
      project: p,
      module: m
    } do
      sim = add(owner, p, m, "simulation", "Orbit lab", %{"body" => "Launch it."})
      assert codes(p, "simulations") == ["sim_goal"]

      update = fn content ->
        lesson = Repo.get!(Lesson, sim.id)

        {:ok, _} =
          Projects.update_lesson(owner, p.id, sim.id, %{
            "lock_version" => lesson.lock_version,
            "content" => content
          })
      end

      update.(%{
        "goal_text" => "Make it round.",
        "velocity" => %{"min" => 4, "max" => 30, "step" => 0.1, "default" => 5}
      })

      assert codes(p, "simulations") == ["sim_params"]
      update.(%{"velocity" => %{"min" => 4, "max" => 9, "step" => 0.1, "default" => 5.05}})
      assert codes(p, "simulations") == ["sim_params"]

      update.(%{
        "velocity" => %{"min" => 4, "max" => 9, "step" => 0.1, "default" => 5},
        "max_eccentricity" => 2
      })

      assert codes(p, "simulations") == ["sim_objective"]
      update.(%{"max_eccentricity" => 0.03})
      assert codes(p, "simulations") == []

      update.(%{
        "model" => "reaction",
        "steps" => 6,
        "species" => [%{"formula" => "H2", "side" => "reactant", "initial" => 10}]
      })

      assert codes(p, "simulations") == ["sim_species"]

      update.(%{
        "species" => [
          %{"formula" => "H2", "side" => "reactant", "initial" => 10},
          %{"formula" => "O2", "side" => "reactant", "initial" => 5},
          %{"formula" => "H2O", "side" => "product", "initial" => 0}
        ]
      })

      assert codes(p, "simulations") == []

      update.(%{
        "species" => [
          %{"formula" => "Ca(OH)2", "side" => "product"},
          %{"formula" => "H2", "side" => "reactant"}
        ]
      })

      assert codes(p, "simulations") == ["sim_species"]
    end

    test "mini-games: items, stars and path", %{owner: owner, project: p, module: m} do
      game =
        add(owner, p, m, "minigame", "Sort it", %{
          "body" => "Order them.",
          "content" => %{"prompt" => "Oldest first.", "items" => ["A tablet", "A chronicle"]}
        })

      assert codes(p, "minigames") == ["game_items"]
      lesson = Repo.get!(Lesson, game.id)

      {:ok, _} =
        Projects.update_lesson(owner, p.id, game.id, %{
          "lock_version" => lesson.lock_version,
          "content" => %{
            "game" => "constellation",
            "stars" => [
              %{"name" => "Alkaid", "x" => 8, "y" => 62},
              %{"name" => "Mizar", "x" => 24, "y" => 50},
              %{"name" => "Alioth", "x" => 37, "y" => 49}
            ],
            "path" => ["Alkaid", "Mizar", "Vega"]
          }
        })

      assert codes(p, "minigames") == ["game_path"]
    end
  end

  describe "import into learning and published media" do
    setup %{owner: owner, project: p, module: m} do
      video = video_lesson(owner, p, m)

      add(owner, p, m, "simulation", "Orbit lab", %{
        "body" => "Launch it.",
        "content" => %{"goal_text" => "Make it round."}
      })

      add(owner, p, m, "minigame", "Sort it", %{
        "body" => "Order them.",
        "content" => %{
          "prompt" => "Oldest first.",
          "items" => ["A tablet", "A chronicle", "A blog"]
        }
      })

      {:ok, _} = p |> attested() |> then(&Publishing.submit(owner, &1.id))

      stub_services(%{
        {"GET", "/api/internal/users/#{@theo}"} => %{
          "user" => %{"id" => @theo, "role" => "moderator"}
        },
        {"POST", "/api/internal/audit"} => {201, %{"id" => 1}}
      })

      {:ok, _} = Publishing.approve(@theo, p.id)
      %{video: Repo.get!(Lesson, video.id)}
    end

    test "the payload carries the media ids, the simulation config and its criterion apart", %{
      project: p,
      video: video
    } do
      [video_id] = [video.content["video_id"]]
      [%{"media_id" => captions_id}] = video.content["captions"]

      # nothing is served to learners before the publication
      assert {:error, :not_found} = Media.fetch_published(video_id)

      stub_services(%{
        {"POST", "/api/internal/adventures/import"} => %{
          "adventure_id" => "a1",
          "slug" => "le-jardin-au-clair-de-lune",
          "version" => 1
        }
      })

      assert :ok = perform_job(ImportWorker, %{project_id: p.id, version: 1})
      assert_received {:service, %{path: "/api/internal/adventures/import", body: body}}
      [%{"lessons" => lessons}] = body["adventure"]["chapters"]
      [_story, _quiz, _coding, video_l, sim_l, game_l] = lessons

      assert %{
               "kind" => "video",
               "content" => %{
                 "video" => %{"media_id" => ^video_id, "content_type" => "video/webm"},
                 "captions" => [
                   %{"media_id" => ^captions_id, "lang" => "en", "label" => "English"}
                 ],
                 "transcript" => "Tonight we read the sky.",
                 "duration_s" => 34
               }
             } = video_l

      assert %{
               "kind" => "simulation",
               "content" => %{
                 "model" => "orbit",
                 "params" => %{"velocity" => %{"label" => "Launch speed", "unit" => "AU/yr"}},
                 "fixed" => %{"distance" => 1, "dt" => 0.002}
               },
               "solution" => %{"max_eccentricity" => 0.03, "min_revolutions" => 1}
             } = sim_l

      refute Map.has_key?(sim_l["content"], "max_eccentricity")

      assert %{
               "content" => %{
                 "game" => "sequence",
                 "items" => ["A tablet", "A chronicle", "A blog"]
               }
             } =
               game_l

      # published: learners get the files through the published route only
      assert {:ok, %Medium{kind: "video"}, _} = Media.fetch_published(video_id)

      assert {:ok, %Medium{kind: "captions", content_type: "text/vtt"}, _} =
               Media.fetch_published(captions_id)

      # back to draft: replacing the video keeps the published file
      {:ok, %{medium: new}} = Media.upload_video(p.owner_id, p.id, video.id, mp4())
      assert {:ok, _, _} = Media.fetch_published(video_id)
      assert {:error, :not_found} = Media.fetch_published(new.id)
    end
  end

  test "the AI only drafts story, quiz and coding lessons", %{owner: owner, project: p, module: m} do
    video = add(owner, p, m, "video", "Film")

    assert {:error, {:invalid, %{lesson_id: ["must be a story, quiz or coding lesson"]}}} =
             AI.create(owner, p.id, %{
               "kind" => "lesson_draft",
               "brief" => "A film about stars",
               "lesson_id" => video.id,
               "confirm_cost" => 5
             })
  end
end
