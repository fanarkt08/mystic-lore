defmodule MlSocial.Attachments do
  @moduledoc """
  Validation, stockage et lecture des pièces jointes, reconnues à leurs octets et passées à l'antivirus.
  L'accès est revérifié à chaque téléchargement, et un refus répond comme un identifiant inconnu.
  """
  import Ecto.Query
  alias MlSocial.{Attachment, Conversation, Friends, Member, Message, Repo, Scanner}

  @image_max 5 * 1024 * 1024
  @pdf_max 10 * 1024 * 1024
  @sides 1..8192
  @alt_max 300

  defp dir, do: Path.join(Application.fetch_env!(:social, :storage_dir), "attachments")
  defp path(key), do: Path.join(dir(), key)

  @doc """
  Valide la pièce jointe d'un envoi (`%{"data_base64", "filename", "alt"}`) sans la stocker : `{:ok, nil}`,
  `{:ok, fichier}`, `{:error, {:invalid, %{attachment: [message]}}}` ou `{:error, :scanner_unavailable}`.
  """
  def prepare(nil), do: {:ok, nil}

  def prepare(%{"data_base64" => data} = params) when is_binary(data) do
    with {:ok, bytes} <- decode(data),
         {:ok, file} <- classify(bytes),
         {:ok, alt} <- alt_text(params["alt"], file.kind),
         {:ok, scan} <- scan(file.data) do
      {:ok, Map.merge(file, %{alt_text: alt, scan: scan, filename: filename(params, file)})}
    end
  end

  def prepare(_params), do: invalid("is invalid")

  defp decode(data) do
    case Base.decode64(data, ignore: :whitespace) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> invalid("is invalid")
    end
  end

  defp classify(<<"%PDF-", _::binary>> = bytes) when byte_size(bytes) > @pdf_max,
    do: invalid("PDF documents must be at most 10 MB")

  defp classify(<<"%PDF-", _::binary>> = bytes),
    do: {:ok, %{kind: "pdf", content_type: "application/pdf", ext: "pdf", data: bytes}}

  defp classify(bytes) do
    case MlShared.Image.sanitize(bytes, max_bytes: @image_max, sides: @sides) do
      {:ok, image} ->
        {:ok,
         %{
           kind: "image",
           content_type: image.type,
           ext: image.ext,
           data: image.data,
           width: image.width,
           height: image.height
         }}

      {:error, :unsupported} ->
        invalid("must be a PNG, JPEG or WebP image, or a PDF document")

      {:error, :too_large} ->
        invalid("images must be at most 5 MB")

      {:error, :malformed} ->
        invalid("is not a valid image file")

      {:error, :dimensions} ->
        invalid("images must be between 1 and 8192 pixels wide and high")
    end
  end

  defp alt_text(_alt, "pdf"), do: {:ok, nil}

  defp alt_text(alt, "image") when is_binary(alt) do
    alt = String.trim(alt)

    cond do
      alt == "" -> {:ok, nil}
      String.length(alt) > @alt_max -> invalid_alt("should be at most 300 character(s)")
      String.contains?(alt, <<0>>) -> invalid_alt("is invalid")
      true -> {:ok, alt}
    end
  end

  defp alt_text(nil, "image"), do: {:ok, nil}
  defp alt_text(_alt, _kind), do: invalid_alt("is invalid")

  defp scan(data) do
    case Scanner.check(data) do
      {:error, :infected} -> invalid("was rejected by the antivirus")
      other -> other
    end
  end

  # Nom affiché et proposé au téléchargement : sans chemin ni caractère de contrôle, 100 caractères, extension réelle.
  defp filename(params, file) do
    name = if is_binary(params["filename"]), do: params["filename"], else: ""

    base =
      name
      |> String.replace("\\", "/")
      |> Path.basename()
      |> Path.rootname()
      |> String.replace(~r/[\p{Cc}\p{Cf}"\/:*?<>|]+/u, "")
      |> String.trim()
      |> String.slice(0, 100)

    base =
      if base in ["", "."], do: if(file.kind == "pdf", do: "document", else: "image"), else: base

    base <> "." <> file.ext
  end

  defp invalid(message), do: {:error, {:invalid, %{attachment: [message]}}}
  defp invalid_alt(message), do: {:error, {:invalid, %{alt: [message]}}}

  @doc "Écrit le fichier (temporaire puis renommage) et renvoie son nom aléatoire."
  def store!(%{data: data, ext: ext}) do
    key = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> "." <> ext
    File.mkdir_p!(dir())
    tmp = path(key <> ".tmp")
    File.write!(tmp, data)
    File.rename!(tmp, path(key))
    key
  end

  @doc "Ligne de la pièce jointe stockée sous `key`, pour le message `message_id`."
  def row(file, key, message_id, uploader_id) do
    %Attachment{
      message_id: message_id,
      uploader_id: uploader_id,
      kind: file.kind,
      content_type: file.content_type,
      byte_size: byte_size(file.data),
      width: file[:width],
      height: file[:height],
      filename: file.filename,
      alt_text: file.alt_text,
      scan: file.scan,
      storage_key: key
    }
  end

  def delete_file(nil), do: :ok

  def delete_file(key) do
    _ = File.rm(path(key))
    :ok
  end

  @doc "Noms des fichiers d'une conversation (à effacer quand un groupe vide est supprimé)."
  def keys(conversation_id) do
    Repo.all(
      from a in Attachment,
        join: m in Message,
        on: m.id == a.message_id,
        where: m.conversation_id == ^conversation_id and not is_nil(a.storage_key),
        select: a.storage_key
    )
  end

  @doc "Téléchargement par un membre : `{:ok, %Attachment{}, octets}` ou `{:error, :not_found}`."
  def read(me, attachment_id) do
    with {:ok, id} <- Ecto.UUID.cast(attachment_id),
         {%Attachment{} = a, %Message{} = m, %Conversation{} = c} <-
           Repo.one(
             from a in Attachment,
               join: m in Message,
               on: m.id == a.message_id,
               join: c in Conversation,
               on: c.id == m.conversation_id,
               join: mb in Member,
               on: mb.conversation_id == c.id and mb.user_id == ^me,
               where: a.id == ^id,
               # groupe : rien d'antérieur à l'arrivée du membre (`MlSocial.Chat`)
               where: c.kind != "group" or m.inserted_at >= mb.joined_at,
               select: {a, m, c}
           ),
         true <- is_nil(m.removed_at),
         false <- Conversation.group?(c) and Friends.blocked?(me, m.sender_id),
         {:ok, a, data} <- file(a) do
      {:ok, a, data}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Octets d'une pièce jointe non effacée, sans contrôle d'accès (preuve du staff, auditée par l'appelant)."
  def file(%Attachment{storage_key: key} = a) when is_binary(key) do
    case File.read(path(key)) do
      {:ok, data} -> {:ok, a, data}
      {:error, _} -> {:error, :not_found}
    end
  end

  def file(_attachment), do: {:error, :not_found}

  @doc "Pièces jointes envoyées par le membre, avec leur contenu (export des données)."
  def export(me) do
    Repo.all(
      from a in Attachment,
        join: m in Message,
        on: m.id == a.message_id,
        where: a.uploader_id == ^me,
        order_by: [a.inserted_at, a.id],
        select: {a, m.conversation_id}
    )
    |> Enum.map(fn {a, conversation_id} ->
      data =
        case file(a) do
          {:ok, _a, bytes} -> Base.encode64(bytes)
          {:error, _} -> nil
        end

      %{
        "id" => a.id,
        "message_id" => a.message_id,
        "conversation_id" => conversation_id,
        "kind" => a.kind,
        "content_type" => a.content_type,
        "filename" => a.filename,
        "byte_size" => a.byte_size,
        "alt_text" => a.alt_text,
        "scan" => a.scan,
        "inserted_at" => a.inserted_at,
        "data_base64" => data
      }
    end)
  end

  @doc "Efface les fichiers du membre supprimé en gardant la place des messages dans le fil (idempotent)."
  def erase(me) do
    query = from a in Attachment, where: a.uploader_id == ^me and is_nil(a.erased_at)

    {:ok, keys} =
      Repo.transact(fn ->
        keys = Repo.all(from a in query, lock: "FOR UPDATE", select: a.storage_key)

        Repo.update_all(query,
          set: [erased_at: DateTime.utc_now(), storage_key: nil, filename: nil, alt_text: nil]
        )

        {:ok, keys}
      end)

    Enum.each(keys, &delete_file/1)
  end
end
