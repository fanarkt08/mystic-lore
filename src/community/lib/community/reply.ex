defmodule MlCommunity.Reply do
  @moduledoc """
  Réponse à une discussion (un seul niveau : on répond à la discussion, pas à une réponse) ; texte brut 2–5 000.
  Même cycle de vie que `MlCommunity.Discussion` (`visible`, `hidden`, `removed`, `deleted`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "replies" do
    belongs_to :discussion, MlCommunity.Discussion
    field :author_id, :binary_id
    field :body, :string
    field :status, :string, default: "visible"
    field :helpful_count, :integer, default: 0
    field :moderation_reason, :string
    field :edited_at, :utc_datetime_usec
    field :voted, :boolean, virtual: true, default: false
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Corps de la réponse ; discussion et auteur sont posés par le serveur."
  def changeset(reply, attrs) do
    reply
    |> cast(attrs, [:body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, min: 2, max: 5_000)
    |> MlCommunity.validate_no_nul([:body])
  end
end
