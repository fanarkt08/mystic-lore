defmodule MlMultiplayer do
  @moduledoc """
  Service multijoueur : salons, invitations, chat, présence, parties « The Rune Relay » et récompenses XP.
  Les événements diffusés ne contiennent jamais d'indice ni le secret : `web` relit la vue de chaque joueur.
  """

  @doc "UUID normalisé (minuscules) ou `:error`."
  def cast_uuid(value) when is_binary(value), do: Ecto.UUID.cast(value)
  def cast_uuid(_), do: :error

  @doc "Règle de jeu/présence configurée (`config :multiplayer, :rules`)."
  def rule(key), do: Application.fetch_env!(:multiplayer, :rules) |> Keyword.fetch!(key)
end
