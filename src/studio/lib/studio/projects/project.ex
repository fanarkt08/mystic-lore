defmodule MlStudio.Projects.Project do
  @moduledoc """
  A course project and its brief. Any content change bumps `content_revision`, which invalidates the
  author's attestations.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @levels ~w(beginner intermediate advanced)
  @categories ~w(coding science humanities creative)
  @covers ~w(forest observatory alchemy archive)
  @brief ~w(title summary description objectives prerequisites audience level duration_minutes category cover)a

  schema "projects" do
    field :owner_id, Ecto.UUID
    field :title, :string
    field :summary, :string, default: ""
    field :description, :string, default: ""
    field :objectives, {:array, :string}, default: []
    field :prerequisites, {:array, :string}, default: []
    field :audience, :string, default: ""
    field :level, :string, default: "beginner"
    field :duration_minutes, :integer, default: 30
    field :category, :string, default: "creative"
    field :cover, :string, default: "forest"
    field :status, :string, default: "draft"
    field :lock_version, :integer, default: 1
    field :content_revision, :integer, default: 1
    field :attestations, :map
    field :attested_revision, :integer
    field :attested_at, :utc_datetime
    field :review_version, :integer
    field :submitted_at, :utc_datetime
    field :reviewed_by, Ecto.UUID
    field :reviewed_at, :utc_datetime
    field :review_reason, :string
    field :import_message, :string
    field :published_slug, :string
    field :published_adventure_id, :string
    field :published_version, :integer
    field :published_at, :utc_datetime
    has_many :modules, MlStudio.Projects.CourseModule, preload_order: [asc: :position]
    has_many :collaborators, MlStudio.Projects.Collaborator, preload_order: [asc: :inserted_at]
    has_many :images, MlStudio.Images.Image, preload_order: [asc: :inserted_at]
    has_many :media, MlStudio.Media.Medium, preload_order: [asc: :inserted_at]
    timestamps()
  end

  def brief_fields, do: @brief

  def brief_changeset(project, attrs) do
    project
    |> cast(attrs, @brief, empty_values: [nil])
    |> update_change(:title, &String.trim/1)
    |> update_change(:objectives, &clean_list/1)
    |> update_change(:prerequisites, &clean_list/1)
    |> validate_required([:title])
    # empty_values: [nil] keeps "" for the other texts, so a blank title is refused here
    |> validate_change(:title, &if(&2 == "", do: [{&1, "can't be blank"}], else: []))
    |> validate_length(:title, max: 200)
    |> validate_length(:summary, max: 1_000)
    |> validate_length(:description, max: 20_000)
    |> validate_length(:audience, max: 300)
    |> validate_inclusion(:level, @levels)
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:cover, @covers)
    |> validate_number(:duration_minutes, greater_than: 0, less_than_or_equal_to: 1_000)
    |> validate_list(:objectives)
    |> validate_list(:prerequisites)
  end

  defp clean_list(items),
    do: items |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp validate_list(changeset, field) do
    validate_change(changeset, field, fn ^field, items ->
      cond do
        length(items) > 20 ->
          [{field, "should have at most 20 item(s)"}]

        Enum.any?(items, &(String.length(&1) > 500)) ->
          [{field, "items should be at most 500 character(s)"}]

        true ->
          []
      end
    end)
  end
end
