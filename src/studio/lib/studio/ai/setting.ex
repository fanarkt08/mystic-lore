defmodule MlStudio.AI.Setting do
  @moduledoc """
  Per-member consent: « share my drafts with an external AI provider » (off by default). Without it,
  a generation by an external provider only receives the brief typed for that generation.
  """
  use Ecto.Schema

  @primary_key {:user_id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime]

  schema "member_settings" do
    field :share_drafts_with_ai, :boolean, default: false
    timestamps()
  end
end
