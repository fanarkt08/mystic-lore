defmodule MlAccounts.SupportRequest do
  @moduledoc "Demande de support envoyée par un membre ou par un visiteur, jamais les deux."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "support_requests" do
    field :reference, :string
    field :user_id, Ecto.UUID
    field :email, :string
    field :topic, :string
    field :message, :string
    field :locale, :string, default: "en"
    field :status, :string, default: "open"
    field :internal_note, :string
    field :answered_at, :utc_datetime
    field :closed_at, :utc_datetime

    has_many :replies, MlAccounts.SupportReply,
      foreign_key: :request_id,
      preload_order: [asc: :inserted_at]

    timestamps(type: :utc_datetime)
  end

  @topics ~w(account billing privacy bug other)
  @statuses ~w(open answered closed)

  def topics, do: @topics
  def statuses, do: @statuses
end
