defmodule MlCommunity.Discussion do
  @moduledoc "Discussion du forum ; son slug est dérivé du titre et ne change plus ensuite."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "discussions" do
    field :category, :string
    field :author_id, :binary_id
    field :title, :string
    field :slug, :string
    field :body, :string
    field :status, :string, default: "visible"
    field :pinned, :boolean, default: false
    field :locked, :boolean, default: false
    field :solution_reply_id, :binary_id
    field :helpful_count, :integer, default: 0
    field :moderation_reason, :string
    field :edited_at, :utc_datetime_usec
    field :last_activity_at, :utc_datetime_usec
    field :category_name, :string, virtual: true
    field :reply_count, :integer, virtual: true, default: 0
    field :following, :boolean, virtual: true, default: false
    field :voted, :boolean, virtual: true, default: false
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Nouvelle discussion ; auteur, slug et dates sont posés par le serveur, jamais castés."
  def create_changeset(discussion, attrs) do
    discussion
    |> cast(attrs, [:category, :title, :body])
    |> validate()
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:category)
  end

  @doc "Édition par l'auteur : titre et corps seulement (la catégorie ne change que par la modération)."
  def edit_changeset(discussion, attrs),
    do: discussion |> cast(attrs, [:title, :body]) |> validate()

  defp validate(changeset) do
    changeset
    |> update_change(:title, &(&1 |> String.split() |> Enum.join(" ")))
    |> update_change(:body, &String.trim/1)
    |> validate_required([:category, :title, :body])
    |> validate_length(:title, min: 5, max: 140)
    |> validate_length(:body, min: 10, max: 10_000)
    |> MlCommunity.validate_no_nul([:title, :body])
  end

  @doc "`\"Pourquoi range(3) ?\"` → `\"pourquoi-range-3-x7k2m9qa\"` : ASCII, minuscules, tirets, suffixe aléatoire."
  def slug(title) do
    suffix = 5 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false)
    slugify(title) <> "-" <> suffix
  end

  def slugify(title) do
    title
    |> to_string()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[^\x00-\x7F]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
    |> String.trim("-")
    |> case do
      "" -> "discussion"
      slug -> slug
    end
  end
end
