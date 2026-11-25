defmodule MlAccountsWeb.ProfilePreferencesTest do
  use MlAccountsWeb.ConnCase, async: true
  use Oban.Testing, repo: MlAccounts.Repo
  import Ecto.Query, only: [from: 2]
  import MlShared.ImageFixtures
  alias MlAccounts.User
  alias MlAccounts.Privacy.{DeletionWorker, ExportWorker}

  @moduletag :capture_log

  setup do
    user = user_fixture(%{display_name: "Léa Moreau", bio: "Botanist."})
    MlShared.Events.subscribe("user:#{user.id}")
    %{user: user}
  end

  defp as(user), do: build_conn() |> internal(user.id)
  defp patch_me(user, params), do: user |> as() |> patch("/api/me", params)
  defp prefs(user, params), do: user |> as() |> patch("/api/me/preferences", params)

  # Faux billing : formule `plan` (ou injoignable) ; chaque appel est rapporté au test.
  defp stub_billing(plan) do
    test = self()

    Req.Test.stub(MlShared.Client, fn conn ->
      send(test, {:billing, conn.request_path})

      case plan do
        :down -> Req.Test.transport_error(conn, :econnrefused)
        plan -> Req.Test.json(conn, %{"plan" => plan, "status" => "active"})
      end
    end)
  end

  describe "profile fields (PATCH /api/me)" do
    test "pronouns, interests, cover and visibility are saved and returned", %{user: user} do
      params = %{
        pronouns: "  she/her ",
        interests: ["astronomy", "coding", "astronomy"],
        cover: "observatory",
        profile_visibility: "friends"
      }

      assert %{
               "user" => %{
                 "pronouns" => "she/her",
                 "interests" => ["astronomy", "coding"],
                 "cover" => "observatory",
                 "profile_visibility" => "friends"
               }
             } = patch_me(user, params) |> json_response(200)

      assert_receive {:profile_changed, id}
      assert id == user.id
    end

    test "validations: 40 characters, no control characters, fixed list of 6 interests", %{
      user: user
    } do
      assert %{"errors" => %{"pronouns" => ["should be at most 40 character(s)"]}} =
               patch_me(user, %{pronouns: String.duplicate("x", 41)}) |> json_response(422)

      for bad <- ["she\nher", "tab\tbed", "nul\u0000", "rtl\u202Eevil"] do
        assert %{"errors" => %{"pronouns" => ["must not contain control characters"]}} =
                 patch_me(user, %{pronouns: bad}) |> json_response(422)
      end

      assert %{"errors" => %{"interests" => ["has an invalid entry"]}} =
               patch_me(user, %{interests: ["astronomy", "cooking"]}) |> json_response(422)

      seven = Enum.take(User.interests(), 7)

      assert %{"errors" => %{"interests" => ["should have at most 6 item(s)"]}} =
               patch_me(user, %{interests: seven}) |> json_response(422)

      assert %{"errors" => %{"interests" => ["is invalid"]}} =
               patch_me(user, %{interests: "astronomy"}) |> json_response(422)

      assert %{"errors" => %{"cover" => ["is invalid"], "profile_visibility" => ["is invalid"]}} =
               patch_me(user, %{cover: "volcano", profile_visibility: "everyone"})
               |> json_response(422)

      assert %{"errors" => %{"profile_visibility" => ["can't be blank"]}} =
               patch_me(user, %{profile_visibility: nil}) |> json_response(422)

      # une valeur vide efface les pronoms ; null efface les centres d'intérêt
      assert %{"user" => %{"pronouns" => nil, "interests" => []}} =
               patch_me(user, %{pronouns: " ", interests: nil}) |> json_response(200)
    end
  end

  describe "preferences (PATCH /api/me/preferences)" do
    test "defaults, partial changes and validation", %{user: user} do
      assert %{"user" => %{"preferences" => defaults}} =
               user |> as() |> get("/api/me") |> json_response(200)

      assert defaults == %{
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

      assert %{"user" => %{"preferences" => saved}} =
               prefs(user, %{
                 language: "fr",
                 time_zone: "Asia/Tokyo",
                 theme: "light",
                 text_size: 150,
                 reduce_motion: true,
                 daily_xp_goal: 50
               })
               |> json_response(200)

      assert %{"language" => "fr", "time_zone" => "Asia/Tokyo", "text_size" => 150} = saved
      assert_receive {:profile_changed, _}

      # les champs absents gardent leur valeur
      assert %{"user" => %{"preferences" => %{"language" => "fr", "captions" => false}}} =
               prefs(user, %{captions: false}) |> json_response(200)

      assert %{
               "errors" => %{
                 "language" => ["is invalid"],
                 "theme" => ["is invalid"],
                 "text_size" => ["is invalid"],
                 "daily_xp_goal" => ["is invalid"],
                 "time_zone" => ["is not a known time zone"]
               }
             } =
               prefs(user, %{
                 language: "de",
                 theme: "neon",
                 text_size: 130,
                 daily_xp_goal: 30,
                 time_zone: "Mars/Olympus_Mons"
               })
               |> json_response(422)

      assert %{"errors" => %{"reduce_motion" => ["can't be blank"]}} =
               prefs(user, %{reduce_motion: nil}) |> json_response(422)

      assert %{"user" => %{"preferences" => %{"time_zone" => "auto"}}} =
               prefs(user, %{time_zone: "auto"}) |> json_response(200)
    end

    test "a VIP theme needs the EFFECTIVE VIP plan at billing", %{user: user} do
      # thème ordinaire : billing n'est pas consulté
      stub_billing("free")
      assert prefs(user, %{theme: "dark"}) |> json_response(200)
      refute_received {:billing, _}

      assert %{"error" => "vip_required"} = prefs(user, %{theme: "grove"}) |> json_response(403)
      assert_received {:billing, path}
      assert path == "/api/entitlements/#{user.id}"

      stub_billing("premium")
      assert %{"error" => "vip_required"} = prefs(user, %{theme: "ember"}) |> json_response(403)
      assert_received {:billing, _}

      # billing injoignable : refus, jamais d'ouverture par défaut
      stub_billing(:down)

      assert %{"error" => "entitlements_unavailable"} =
               prefs(user, %{theme: "parchment"}) |> json_response(503)

      assert_received {:billing, _}

      assert Repo.reload!(user).preferences.theme == "dark"

      stub_billing("vip")

      assert %{"user" => %{"preferences" => %{"theme" => "grove"}}} =
               prefs(user, %{theme: "grove"}) |> json_response(200)

      assert_received {:billing, _}

      # le thème VIP déjà enregistré ne bloque pas les autres réglages, même sans VIP
      stub_billing("free")

      assert %{"user" => %{"preferences" => %{"theme" => "grove", "text_size" => 125}}} =
               prefs(user, %{theme: "grove", text_size: 125}) |> json_response(200)

      refute_received {:billing, _}
    end
  end

  describe "export and deletion" do
    setup %{user: user} do
      stub_services()
      {:ok, _} = MlAccounts.Avatars.upload(user, png(96, 96, [{"tEXt", "Author\0Lyra"}]))

      {:ok, user} =
        MlAccounts.update_profile(Repo.reload!(user), %{
          "pronouns" => "she/her",
          "interests" => ["botany"],
          "cover" => "forest",
          "profile_visibility" => "public"
        })

      {:ok, user} = MlAccounts.update_preferences(user, %{"theme" => "light"})
      %{user: user}
    end

    defp stub_services do
      Req.Test.stub(MlShared.Client, fn conn ->
        if conn.method == "DELETE",
          do: Plug.Conn.send_resp(conn, 204, ""),
          else: Req.Test.json(conn, %{"data" => %{}})
      end)
    end

    test "the export holds the new profile data, the preferences and the avatar itself", %{
      user: user
    } do
      %{"id" => id} =
        user |> as() |> post("/api/me/exports", %{password: password()}) |> json_response(202)

      assert :ok = perform_job(ExportWorker, %{export_id: id}, attempt: 1, max_attempts: 6)

      %{"services" => %{"accounts" => accounts}} =
        user |> as() |> get("/api/me/exports/#{id}/download") |> json_response(200)

      assert %{
               "pronouns" => "she/her",
               "interests" => ["botany"],
               "cover" => "forest",
               "profile_visibility" => "public",
               "avatar" => %{
                 "kind" => "image",
                 "content_type" => "image/png",
                 "data_base64" => b64
               }
             } = accounts["profile"]

      assert Base.decode64!(b64) == png(96, 96)
      assert accounts["preferences"]["theme"] == "light"
    end

    test "the deletion clears the profile and erases the avatar file", %{user: user} do
      file =
        Path.join([Application.fetch_env!(:accounts, :storage_dir), "avatars", user.avatar_image])

      assert File.exists?(file)

      past = DateTime.add(DateTime.utc_now(:second), -60)

      Repo.update_all(from(u in User, where: u.id == ^user.id),
        set: [deletion_scheduled_at: past]
      )

      assert :ok = perform_job(DeletionWorker, %{user_id: user.id})

      deleted = Repo.reload!(user)
      assert deleted.deleted_at
      assert {deleted.pronouns, deleted.interests, deleted.cover} == {nil, [], nil}
      assert {deleted.avatar_image, deleted.avatar_crest} == {nil, nil}
      assert deleted.preferences == %MlAccounts.Preferences{}
      refute File.exists?(file)

      assert build_conn()
             |> internal()
             |> get("/api/avatars/#{user.avatar_image}")
             |> response(404)
    end
  end
end
