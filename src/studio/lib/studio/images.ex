defmodule MlStudio.Images do
  @moduledoc """
  Project illustrations, recognised by their signature and served only to authorized members.
  """
  import Ecto.Query
  alias MlStudio.{Projects, Repo, Services}
  alias MlStudio.Images.Image

  @max_bytes 2 * 1024 * 1024
  @max_per_project 30

  def max_bytes, do: @max_bytes

  def path(%Image{project_id: project_id, id: id}), do: Path.join([dir(), project_id, id])
  defp dir, do: Application.fetch_env!(:studio, :storage_dir)

  def upload(user_id, project_id, params) do
    with {:ok, data} <- decode(params["data"]),
         {:ok, type} <- sniff(data),
         {:ok, alt} <- alt(params["alt"]) do
      Projects.change_content(user_id, project_id, :edit, fn project, _role ->
        with {:ok, lesson_id} <- lesson_ref(project, params["lesson_id"]),
             :ok <- room(project) do
          image =
            Repo.insert!(%Image{
              project_id: project.id,
              lesson_id: lesson_id,
              uploader_id: user_id,
              alt: alt,
              content_type: type,
              byte_size: byte_size(data),
              source: "upload"
            })

          write!(image, data)
          {:ok, image}
        end
      end)
    end
  end

  @doc "Stores an image produced by the demo generator (no alternative text yet)."
  def store_generated(project_id, lesson_id, user_id, %{data: data, content_type: type}) do
    image =
      Repo.insert!(%Image{
        project_id: project_id,
        lesson_id: lesson_id,
        uploader_id: user_id,
        content_type: type,
        byte_size: byte_size(data),
        source: "demo"
      })

    write!(image, data)
    image
  end

  def update(user_id, project_id, image_id, params) do
    Projects.change_content(user_id, project_id, :edit, fn project, _role ->
      with {:ok, image} <- find(project, image_id),
           {:ok, alt} <- alt(params["alt"]),
           {:ok, lesson_id} <- lesson_ref(project, Map.get(params, "lesson_id", image.lesson_id)) do
        {:ok, image |> Ecto.Changeset.change(alt: alt, lesson_id: lesson_id) |> Repo.update!()}
      end
    end)
  end

  def delete(user_id, project_id, image_id) do
    Projects.change_content(user_id, project_id, :edit, fn project, _role ->
      with {:ok, image} <- find(project, image_id) do
        Repo.delete!(image)
        File.rm(path(image))
        {:ok, :deleted}
      end
    end)
  end

  @doc "`{:ok, image, path}` for a member of the project, or staff once it was submitted."
  def fetch(user_id, project_id, image_id) do
    with {:ok, project} <- readable(user_id, project_id),
         {:ok, image} <- find(project, image_id),
         true <- File.exists?(path(image)) do
      {:ok, image, path(image)}
    else
      {:error, _} = error -> error
      false -> {:error, :not_found}
    end
  end

  def remove_files(project_id), do: File.rm_rf(Path.join(dir(), project_id))

  @doc "Image type from the file signature (magic bytes)."
  def sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: {:ok, "image/png"}
  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  def sniff(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  def sniff(_data), do: invalid(:data, "must be a PNG, JPEG or WebP image")

  @doc false
  # a member of the project, or the staff once it was submitted (also used by MlStudio.Media)
  def readable(user_id, project_id) do
    case Projects.access(user_id, project_id, :view) do
      {:ok, project, _role} -> {:ok, project}
      {:error, :not_found} -> in_review_for_staff(user_id, project_id)
      error -> error
    end
  end

  defp in_review_for_staff(user_id, project_id) do
    with {:ok, id} <- Ecto.UUID.cast(project_id),
         %{status: status} = project when status in ["submitted", "approved", "published"] <-
           Repo.get(MlStudio.Projects.Project, id),
         {:ok, true} <- Services.staff?(user_id) do
      {:ok, project}
    else
      _ -> {:error, :not_found}
    end
  end

  defp decode(data) when is_binary(data) do
    case Base.decode64(data, ignore: :whitespace) do
      {:ok, ""} -> invalid(:data, "can't be blank")
      {:ok, bin} when byte_size(bin) > @max_bytes -> invalid(:data, "must be at most 2 MB")
      {:ok, bin} -> {:ok, bin}
      :error -> invalid(:data, "must be base64-encoded")
    end
  end

  defp decode(_data), do: invalid(:data, "can't be blank")

  defp alt(alt) when is_binary(alt) do
    case String.trim(alt) do
      "" ->
        invalid(:alt, "can't be blank")

      text ->
        if String.length(text) <= 300,
          do: {:ok, text},
          else: invalid(:alt, "should be at most 300 character(s)")
    end
  end

  defp alt(_alt), do: invalid(:alt, "can't be blank")

  defp lesson_ref(_project, nil), do: {:ok, nil}

  defp lesson_ref(project, lesson_id) do
    case Projects.lesson(project, lesson_id) do
      {:ok, lesson} -> {:ok, lesson.id}
      {:error, :not_found} -> invalid(:lesson_id, "is invalid")
    end
  end

  defp room(project) do
    if Repo.aggregate(from(i in Image, where: i.project_id == ^project.id), :count) <
         @max_per_project,
       do: :ok,
       else: {:error, :too_many_images}
  end

  defp find(project, image_id) do
    with {:ok, id} <- Ecto.UUID.cast(image_id),
         %Image{} = image <- Repo.get_by(Image, id: id, project_id: project.id) do
      {:ok, image}
    else
      _ -> {:error, :not_found}
    end
  end

  defp write!(image, data) do
    File.mkdir_p!(Path.dirname(path(image)))
    File.write!(path(image), data)
  end

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}
end
