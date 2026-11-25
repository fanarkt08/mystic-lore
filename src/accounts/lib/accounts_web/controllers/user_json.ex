defmodule MlAccountsWeb.UserJSON do
  @moduledoc """
  Formes du contrat : « user public » (identité, toujours visible : jamais la bio ni le reste du profil, filtrés
  par `MlAccounts.Profiles`) et « user privé » (le membre lui-même : profil complet et préférences).
  """
  alias MlAccounts.{Avatars, Preferences, User}

  def public(%User{} = user) do
    %{
      id: user.id,
      username: user.username,
      display_name: user.display_name,
      avatar: Avatars.public(user)
    }
  end

  def private(%User{} = user) do
    Map.merge(public(user), %{
      bio: user.bio,
      pronouns: user.pronouns,
      interests: user.interests,
      cover: user.cover,
      profile_visibility: user.profile_visibility,
      preferences: Preferences.to_map(user.preferences),
      email: user.email,
      confirmed: not is_nil(user.confirmed_at),
      role: user.role,
      inserted_at: user.inserted_at,
      # suppression programmée : date d'échéance (le membre peut encore l'annuler), sinon nil
      deletion_scheduled_at: user.deletion_scheduled_at,
      # restriction en cours (sanction du staff) : date de fin, sinon nil
      restricted_until: MlAccounts.Sanctions.restricted_until(user),
      # accueil guidé : `pending` = proposé à la connexion
      onboarding: %{status: user.onboarding_status, at: user.onboarding_at}
    })
  end
end
