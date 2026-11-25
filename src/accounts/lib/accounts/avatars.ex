defmodule MlAccounts.Avatars do
  @moduledoc """
  Avatar d'un membre : un blason préréglé, une image téléversée et nettoyée, ou rien.
  Le nom de l'image est aléatoire et change à chaque envoi, ce qui sert de version de cache.
  """
  import Ecto.Query
  alias MlAccounts.{Audit, Repo, Staff, User}

  @max_bytes 2_097_152
  @name ~r/\A[0-9a-f]{32}\.(png|jpg|webp)\z/
  @types %{".png" => "image/png", ".jpg" => "image/jpeg", ".webp" => "image/webp"}

  @doc "Taille maximale d'une image d'avatar (2 Mo) : lecture du corps de la requête bornée."
  def max_bytes, do: @max_bytes

  defp dir, do: Path.join(Application.fetch_env!(:accounts, :storage_dir), "avatars")
  defp path(name), do: Path.join(dir(), name)

  @doc "Forme publique : `nil`, `%{kind: \"crest\", key}` ou `%{kind: \"image\", key: nom du fichier}`."
  def public(%User{avatar_image: name}) when is_binary(name), do: %{kind: "image", key: name}
  def public(%User{avatar_crest: crest}) when is_binary(crest), do: %{kind: "crest", key: crest}
  def public(%User{}), do: nil

  @doc "Nouvelle image : `{:ok, user}` ou `{:error, {:invalid, %{avatar: [message]}}}`."
  def upload(%User{} = user, bytes) do
    case MlShared.Image.sanitize(bytes, max_bytes: @max_bytes, sides: 64..2048) do
      {:ok, image} ->
        name = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> "." <> image.ext
        write(name, image.data)

        with {:error, _} = error <- replace(user, avatar_image: name, avatar_crest: nil) do
          File.rm(path(name))
          error
        end

      {:error, reason} ->
        {:error, {:invalid, %{avatar: [message(reason)]}}}
    end
  end

  defp message(:too_large), do: "must be at most 2 MB"
  defp message(:unsupported), do: "must be a PNG, JPEG or WebP image"
  defp message(:malformed), do: "is not a valid image file"
  defp message(:dimensions), do: "must be between 64 and 2048 pixels wide and high"

  @doc "Blason préréglé (l'image téléversée éventuelle est supprimée)."
  def choose_crest(%User{} = user, crest) do
    if crest in User.crests(),
      do: replace(user, avatar_crest: crest, avatar_image: nil),
      else: {:error, {:invalid, %{crest: ["is invalid"]}}}
  end

  @doc "Plus d'avatar : les initiales sont affichées."
  def remove(%User{} = user), do: replace(user, avatar_crest: nil, avatar_image: nil)

  @doc "Réinitialise l'avatar d'un membre à la demande du staff, avec un motif obligatoire."
  def reset(%User{} = staff, target_id, reason) do
    reason = MlAccounts.Sanctions.trimmed(reason)

    cond do
      is_nil(reason) or String.length(reason) < 5 or String.length(reason) > 500 ->
        {:error, {:invalid, %{reason: ["should be 5 to 500 character(s)"]}}}

      target = Staff.get_member(target_id) ->
        replace(target, [avatar_crest: nil, avatar_image: nil], fn before ->
          kind = if before.avatar_image, do: "image", else: "crest"
          Audit.record!(staff.id, "avatar.reset", "user", before.id, reason, %{"kind" => kind})
        end)

      true ->
        {:error, :not_found}
    end
  end

  # Le verrou de ligne évite qu'un téléversement simultané laisse un fichier orphelin.
  defp replace(%User{id: id}, changes, audit \\ fn _before -> :ok end) do
    Repo.transact(fn ->
      before = Repo.one!(from u in User, where: u.id == ^id, lock: "FOR UPDATE")
      changeset = Ecto.Changeset.change(before, changes)

      if changeset.changes == %{} do
        {:ok, {before, nil}}
      else
        with {:ok, user} <- Repo.update(changeset) do
          audit.(before)
          {:ok, {user, before}}
        end
      end
    end)
    |> case do
      {:ok, {user, nil}} ->
        {:ok, user}

      {:ok, {user, before}} ->
        delete_file(before.avatar_image)
        MlAccounts.profile_changed(user.id)
        {:ok, user}

      error ->
        error
    end
  end

  @doc "Image actuelle d'un compte actif : `{:ok, type, octets}` ou `:error` (nom invalide, ancien, absent)."
  def read(name) when is_binary(name) do
    with true <- Regex.match?(@name, name),
         true <-
           Repo.exists?(from u in User, where: u.avatar_image == ^name and is_nil(u.deleted_at)),
         {:ok, bytes} <- File.read(path(name)) do
      {:ok, Map.fetch!(@types, Path.extname(name)), bytes}
    else
      _ -> :error
    end
  end

  def read(_name), do: :error

  @doc "Avatar dans l'export des données : blason, ou image en Base64 avec son type."
  def export(%User{avatar_image: name}) when is_binary(name) do
    case read(name) do
      {:ok, type, bytes} ->
        %{"kind" => "image", "content_type" => type, "data_base64" => Base.encode64(bytes)}

      :error ->
        %{"kind" => "image", "content_type" => nil, "data_base64" => nil}
    end
  end

  def export(%User{avatar_crest: crest}) when is_binary(crest),
    do: %{"kind" => "crest", "key" => crest}

  def export(%User{}), do: nil

  @doc "Supprime le fichier d'une image (ancienne, remplacée, ou d'un compte anonymisé)."
  def delete_file(nil), do: :ok

  def delete_file(name) do
    _ = File.rm(path(name))
    :ok
  end

  defp write(name, data) do
    File.mkdir_p!(dir())
    tmp = path(name <> ".tmp")
    File.write!(tmp, data)
    File.rename!(tmp, path(name))
  end
end
