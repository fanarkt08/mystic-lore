defmodule MlBilling.CheckoutSession do
  @moduledoc "A checkout started by a user, valid one hour and completed only by a signed event."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]

  schema "checkout_sessions" do
    field :user_id, Ecto.UUID
    field :plan, :string
    field :status, :string, default: "open"
    field :provider, :string
    field :provider_session_id, :string
    field :expires_at, :utc_datetime
    timestamps()
  end

  def status(session, now \\ DateTime.utc_now())

  def status(%__MODULE__{status: "open", expires_at: at}, now),
    do: if(DateTime.before?(now, at), do: "open", else: "expired")

  def status(%__MODULE__{status: status}, _now), do: status
end
