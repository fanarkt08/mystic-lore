defmodule MlSocial.Attachment do
  @moduledoc """
  Pièce jointe d'un message, image nettoyée ou PDF, stockée sous un nom aléatoire.
  Un fichier n'est jamais présenté comme analysé par l'antivirus sans l'avoir été.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "attachments" do
    field :message_id, :binary_id
    field :uploader_id, :binary_id
    field :kind, :string
    field :content_type, :string
    field :byte_size, :integer
    field :width, :integer
    field :height, :integer
    field :filename, :string
    field :alt_text, :string
    field :scan, :string
    field :storage_key, :string
    field :erased_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Forme du contrat (métadonnées seulement : les octets passent par `GET /api/attachments/:id`)."
  def to_map(%__MODULE__{} = a) do
    %{
      "id" => a.id,
      "kind" => a.kind,
      "content_type" => a.content_type,
      "filename" => a.filename,
      "byte_size" => a.byte_size,
      "width" => a.width,
      "height" => a.height,
      "alt" => a.alt_text,
      "scan" => a.scan,
      "available" => is_nil(a.erased_at)
    }
  end
end
