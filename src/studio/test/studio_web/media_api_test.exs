defmodule MlStudioWeb.MediaApiTest do
  use MlStudioWeb.ConnCase, async: true
  alias MlStudio.Projects

  @vtt "WEBVTT\n\n00:00.500 --> 00:04.000\nTonight we read the sky.\n"

  setup %{conn: conn} do
    owner = uuid()
    project = project_fixture(owner)
    module = hd(Projects.load(project).modules)
    video = lesson!(owner, project, module, "video", "Film", %{"body" => "Watch."})
    {:ok, conn: conn, owner: owner, project: project, video: video, me: as_user(conn, owner)}
  end

  defp upload(conn, path, bytes),
    do:
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post(path, bytes)

  test "raw video upload, captions, member-only files, published-only route", %{
    conn: conn,
    project: p,
    video: video,
    me: me
  } do
    base = "/api/projects/#{p.id}/lessons/#{video.id}"

    webm =
      <<0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x82, 0x84, "webm">> <> :crypto.strong_rand_bytes(64)

    assert %{"errors" => %{"data" => ["must be a WebM or MP4 video"]}} =
             me |> upload("#{base}/video", "GIF89a....") |> json_response(422)

    assert %{
             "media" => %{"id" => media_id, "kind" => "video", "content_type" => "video/webm"},
             "lesson" => lesson
           } =
             me |> upload("#{base}/video", webm) |> json_response(201)

    assert lesson["content"]["video_id"] == media_id

    assert %{"media" => %{"id" => vtt_id, "kind" => "captions", "lang" => "en"}} =
             me
             |> post("#{base}/captions", %{"lang" => "en", "label" => "English", "vtt" => @vtt})
             |> json_response(201)

    assert %{"errors" => %{"vtt" => _}} =
             me
             |> post("#{base}/captions", %{
               "lang" => "fr",
               "label" => "Français",
               "vtt" => "bonjour"
             })
             |> json_response(422)

    file = me |> get("/api/projects/#{p.id}/media/#{media_id}")
    assert response(file, 200) == webm
    assert get_resp_header(file, "content-type") == ["video/webm"]
    assert get_resp_header(file, "x-content-type-options") == ["nosniff"]

    captions = me |> get("/api/projects/#{p.id}/media/#{vtt_id}")
    assert response(captions, 200) == @vtt
    assert get_resp_header(captions, "content-type") == ["text/vtt; charset=utf-8"]

    # a stranger: nothing (drafts are never disclosed), the published route: not published yet
    stranger = as_user(conn, uuid())
    assert stranger |> get("/api/projects/#{p.id}/media/#{media_id}") |> json_response(404)
    assert stranger |> get("/api/media/#{media_id}") |> json_response(404)

    assert %{"project" => %{"media" => [_, _]}} =
             me |> get("/api/projects/#{p.id}") |> json_response(200)

    assert me |> delete("#{base}/captions/en") |> response(204)
    assert me |> delete("#{base}/captions/en") |> json_response(404)
  end

  test "a viewer can't upload; a project in review is locked", %{
    conn: conn,
    owner: owner,
    project: p,
    video: video
  } do
    viewer = uuid()

    {:ok, _} =
      Repo.insert(%MlStudio.Projects.Collaborator{
        project_id: p.id,
        user_id: viewer,
        username: "hugo_bernard",
        role: "viewer",
        invited_by: owner
      })

    path = "/api/projects/#{p.id}/lessons/#{video.id}/video"
    mp4 = <<0, 0, 0, 24, "ftypisom">> <> :crypto.strong_rand_bytes(64)

    assert %{"error" => "forbidden"} =
             conn |> as_user(viewer) |> upload(path, mp4) |> json_response(403)

    Repo.update_all(from(pr in MlStudio.Projects.Project, where: pr.id == ^p.id),
      set: [status: "submitted"]
    )

    assert %{"error" => "locked"} =
             conn |> as_user(owner) |> upload(path, mp4) |> json_response(409)
  end
end
