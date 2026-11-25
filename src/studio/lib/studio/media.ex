defmodule MlStudio.Media do
  @moduledoc """
  Videos and WebVTT caption tracks of the video lessons, kept in private storage.
  Learners only get the media of the version published in learning.
  """
  import Ecto.Query
  alias MlStudio.{Images, Projects, Repo, WebVTT}
  alias MlStudio.Media.Medium
  alias MlStudio.Projects.{Lesson, Project, Version}

  @max_video 50 * 1024 * 1024
  @max_per_project 40
  @max_tracks 6

  def max_video_bytes, do: @max_video

  def path(%Medium{project_id: project_id, id: id}), do: Path.join([dir(), project_id, id])
  defp dir, do: Application.fetch_env!(:studio, :storage_dir)

  @doc "Stores `data` (raw bytes) as the video of a video lesson: `{:ok, %{medium, lesson}}`."
  def upload_video(user_id, project_id, lesson_id, data) when is_binary(data) do
    with {:ok, type} <- sniff(data) do
      Projects.change_content(user_id, project_id, :edit, fn project, _role ->
        with {:ok, lesson} <- video_lesson(project, lesson_id),
             :ok <- room(project) do
          medium = insert!(project, user_id, "video", type, data, nil, nil)
          old = lesson.content["video_id"]
          lesson = set_content(lesson, %{"video_id" => medium.id})
          discard(project, old)
          {:ok, %{medium: medium, lesson: lesson}}
        end
      end)
    end
  end

  @doc "Adds (or replaces, same language) a WebVTT caption track: `{:ok, %{medium, lesson}}`."
  def add_captions(user_id, project_id, lesson_id, params) do
    with {:ok, lang} <- lang(params["lang"]),
         {:ok, label} <- label(params["label"]),
         {:ok, vtt} <- vtt(params["vtt"]) do
      Projects.change_content(user_id, project_id, :edit, fn project, _role ->
        with {:ok, lesson} <- video_lesson(project, lesson_id),
             :ok <- room(project) do
          {same, others} = Enum.split_with(lesson.content["captions"], &(&1["lang"] == lang))

          if length(others) >= @max_tracks do
            {:error, :too_many_captions}
          else
            medium = insert!(project, user_id, "captions", "text/vtt", vtt, lang, label)
            track = %{"media_id" => medium.id, "lang" => lang, "label" => label}
            lesson = set_content(lesson, %{"captions" => others ++ [track]})
            Enum.each(same, &discard(project, &1["media_id"]))
            {:ok, %{medium: medium, lesson: lesson}}
          end
        end
      end)
    end
  end

  @doc "Removes the caption track of `lang` from a video lesson."
  def delete_captions(user_id, project_id, lesson_id, lang) do
    Projects.change_content(user_id, project_id, :edit, fn project, _role ->
      with {:ok, lesson} <- video_lesson(project, lesson_id) do
        case Enum.split_with(lesson.content["captions"], &(&1["lang"] == lang)) do
          {[], _} ->
            {:error, :not_found}

          {removed, kept} ->
            set_content(lesson, %{"captions" => kept})
            Enum.each(removed, &discard(project, &1["media_id"]))
            {:ok, :deleted}
        end
      end
    end)
  end

  @doc "`{:ok, medium, path}` for a member of the project, or the staff once it was submitted."
  def fetch(user_id, project_id, media_id) do
    with {:ok, project} <- Images.readable(user_id, project_id),
         {:ok, id} <- cast(media_id),
         %Medium{} = medium <- Repo.get_by(Medium, id: id, project_id: project.id),
         true <- File.exists?(path(medium)) do
      {:ok, medium, path(medium)}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc "`{:ok, medium, path}` only for a medium of the version published in learning (any member)."
  def fetch_published(media_id) do
    with {:ok, id} <- cast(media_id),
         %Medium{} = medium <- Repo.get(Medium, id),
         true <- published?(medium.project_id, medium.id),
         true <- File.exists?(path(medium)) do
      {:ok, medium, path(medium)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Media type from the file signature (WebM or MP4)."
  def sniff(data) when byte_size(data) == 0, do: invalid(:data, "can't be blank")
  def sniff(data) when byte_size(data) > @max_video, do: invalid(:data, "must be at most 50 MB")

  def sniff(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>> = data) do
    if :binary.match(binary_part(data, 0, min(byte_size(data), 64)), "webm") != :nomatch,
      do: {:ok, "video/webm"},
      else: invalid(:data, "must be a WebM or MP4 video")
  end

  def sniff(<<_size::binary-size(4), "ftyp", _::binary>>), do: {:ok, "video/mp4"}
  def sniff(_data), do: invalid(:data, "must be a WebM or MP4 video")

  ## Helpers

  defp video_lesson(project, lesson_id) do
    case Projects.lesson(project, lesson_id) do
      {:ok, %Lesson{kind: "video"} = lesson} -> {:ok, lesson}
      {:ok, _other} -> invalid(:lesson_id, "must be a video lesson")
      error -> error
    end
  end

  defp room(project) do
    if Repo.aggregate(from(m in Medium, where: m.project_id == ^project.id), :count) <
         @max_per_project,
       do: :ok,
       else: {:error, :too_many_media}
  end

  defp insert!(project, user_id, kind, type, data, lang, label) do
    medium =
      Repo.insert!(%Medium{
        project_id: project.id,
        uploader_id: user_id,
        kind: kind,
        content_type: type,
        byte_size: byte_size(data),
        lang: lang,
        label: label
      })

    File.mkdir_p!(Path.dirname(path(medium)))
    File.write!(path(medium), data)
    medium
  end

  # the lesson's media references change: its lock_version too (open editors reload it)
  defp set_content(lesson, changes) do
    lesson
    |> Ecto.Changeset.change(
      content: Map.merge(lesson.content, changes),
      lock_version: lesson.lock_version + 1
    )
    |> Repo.update!()
  end

  # a replaced medium is deleted, unless the published adventure still uses it
  defp discard(_project, nil), do: :ok

  defp discard(project, media_id) do
    with %Medium{} = medium <- Repo.get_by(Medium, id: media_id, project_id: project.id),
         false <- published?(project.id, medium.id) do
      Repo.delete!(medium)
      File.rm(path(medium))
    end

    :ok
  end

  defp published?(project_id, media_id) do
    with %Project{published_version: number} when is_integer(number) <-
           Repo.get(Project, project_id),
         %Version{snapshot: snapshot} <-
           Repo.get_by(Version, project_id: project_id, number: number) do
      Enum.any?(snapshot["media"] || [], &(&1["id"] == media_id))
    else
      _ -> false
    end
  end

  defp lang(lang) when is_binary(lang) do
    if lang =~ ~r/^[a-z]{2}(-[A-Z]{2})?$/,
      do: {:ok, lang},
      else: invalid(:lang, "must be a language code like en or pt-BR")
  end

  defp lang(_lang), do: invalid(:lang, "can't be blank")

  defp label(label) when is_binary(label) do
    label = String.trim(label)

    if String.length(label) in 1..40,
      do: {:ok, label},
      else: invalid(:label, "should be 1 to 40 character(s)")
  end

  defp label(_label), do: invalid(:label, "can't be blank")

  defp vtt(text) do
    case WebVTT.validate(text) do
      {:ok, _cues} -> {:ok, text}
      {:error, message} -> invalid(:vtt, message)
    end
  end

  defp cast(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast(_id), do: :error

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
