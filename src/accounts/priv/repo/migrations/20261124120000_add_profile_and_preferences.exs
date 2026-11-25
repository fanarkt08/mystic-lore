defmodule MlAccounts.Repo.Migrations.AddProfileAndPreferences do
  use Ecto.Migration

  # Profil enrichi et préférences. Uniquement additive.
  def change do
    alter table(:users) do
      add :pronouns, :string
      add :interests, {:array, :string}, null: false, default: []
      add :cover, :string
      add :profile_visibility, :string, null: false, default: "members"

      # avatar : un blason préréglé OU une image téléversée (nom de fichier aléatoire), jamais les deux
      add :avatar_crest, :string
      add :avatar_image, :string

      # préférences (langue, fuseau, apparence, accessibilité, apprentissage) : `MlAccounts.Preferences`
      add :preferences, :map, null: false, default: %{}
    end

    create constraint(:users, :users_profile_visibility,
             check: "profile_visibility IN ('public', 'members', 'friends', 'private')"
           )

    create constraint(:users, :users_one_avatar,
             check: "avatar_crest IS NULL OR avatar_image IS NULL"
           )

    create unique_index(:users, [:avatar_image], where: "avatar_image IS NOT NULL")
  end
end
