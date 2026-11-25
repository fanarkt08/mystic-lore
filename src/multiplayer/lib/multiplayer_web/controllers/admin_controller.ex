defmodule MlMultiplayerWeb.AdminController do
  @moduledoc "Indicateurs du staff (rôle moderator/admin vérifié chez accounts) : salons ouverts, parties des 7 derniers jours."
  use MlMultiplayerWeb, :controller
  import Ecto.Query
  alias MlMultiplayer.{Accounts, Lobby, Match, Repo}

  action_fallback MlMultiplayerWeb.FallbackController

  def stats(conn, _params) do
    with :ok <- Accounts.require_staff(conn.assigns.user_id) do
      week_ago = DateTime.add(DateTime.utc_now(), -7, :day)

      json(conn, %{
        stats: %{
          open_lobbies: Repo.aggregate(from(l in Lobby, where: l.status != "closed"), :count),
          matches_7d: Repo.aggregate(from(m in Match, where: m.inserted_at > ^week_ago), :count)
        }
      })
    end
  end
end
