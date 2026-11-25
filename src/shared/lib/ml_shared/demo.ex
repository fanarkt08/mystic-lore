defmodule MlShared.Demo do
  @moduledoc """
  Membres de démo fictifs, à UUID fixes pour que les seeds des différentes bases concordent.
  En production, les seeds exigent un `SEED_DEMO_PASSWORD` secret : le mot de passe de dev n'y sert jamais.
  """
  @users [
    %{
      id: "00000000-0000-4000-8000-000000000001",
      username: "lea_moreau",
      display_name: "Léa Moreau",
      email: "lyra@mysticlore.test",
      plan: "premium",
      role: "user"
    },
    %{
      id: "00000000-0000-4000-8000-000000000002",
      username: "hugo_bernard",
      display_name: "Hugo Bernard",
      email: "orion@mysticlore.test",
      plan: "free",
      role: "user"
    },
    %{
      id: "00000000-0000-4000-8000-000000000003",
      username: "ines_petit",
      display_name: "Inès Petit",
      email: "mika@mysticlore.test",
      plan: "vip",
      role: "user"
    },
    %{
      id: "00000000-0000-4000-8000-000000000004",
      username: "sarah_lefevre",
      display_name: "Sarah Lefèvre",
      email: "samira@mysticlore.test",
      plan: "free",
      role: "user"
    },
    %{
      id: "00000000-0000-4000-8000-000000000005",
      username: "theo_garnier",
      display_name: "Théo Garnier",
      email: "theo@mysticlore.test",
      plan: "free",
      role: "moderator"
    },
    %{
      id: "00000000-0000-4000-8000-000000000006",
      username: "clara_dubois",
      display_name: "Clara Dubois",
      email: "aster@mysticlore.test",
      plan: "free",
      role: "admin"
    }
  ]

  def users, do: @users
  def user(username), do: Enum.find(@users, &(&1.username == username))
  def password, do: System.get_env("SEED_DEMO_PASSWORD", "mystic-demo-pass-1")
end
