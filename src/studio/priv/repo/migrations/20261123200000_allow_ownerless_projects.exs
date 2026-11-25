defmodule MlStudio.Repo.Migrations.AllowOwnerlessProjects do
  use Ecto.Migration

  # Suppression de compte : un projet collaboratif ou publié est conservé sans propriétaire.
  def change do
    alter table(:projects) do
      modify :owner_id, :binary_id, null: true, from: {:binary_id, null: false}
    end
  end
end
