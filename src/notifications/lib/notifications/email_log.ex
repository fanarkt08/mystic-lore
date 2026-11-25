defmodule MlNotifications.EmailLog do
  @moduledoc """
  E-mail demandé à accounts (ligne écrite à la mise en file), qui sert à la limite de débit. `sent_at` n'est
  posé qu'après la confirmation d'accounts : rien n'est annoncé comme envoyé avant.
  """
  use Ecto.Schema

  schema "email_log" do
    field :user_id, :binary_id
    field :dedupe_key, :string
    field :category, :string
    field :kind, :string
    field :inserted_at, :utc_datetime_usec
    field :sent_at, :utc_datetime_usec
  end
end
