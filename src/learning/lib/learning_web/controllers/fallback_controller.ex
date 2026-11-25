defmodule MlLearningWeb.FallbackController do
  @moduledoc "Traduit les erreurs des contextes en réponses du contrat : `{\"error\": code}` + statut."
  use MlLearningWeb, :controller

  @statuses %{
    not_found: 404,
    premium_required: 402,
    entitlements_unavailable: 503,
    equip_limit_exceeded: 422,
    badge_not_earned: 422,
    # leçons hors ligne
    offline_unavailable: 422,
    no_paid_period: 409,
    idempotency_key_reused: 422
  }

  def call(conn, {:error, {:invalid, errors}}),
    do: conn |> put_status(422) |> json(%{error: "invalid", errors: errors})

  # action hors ligne préparée sur une autre version de la leçon : jamais corrigée contre un autre énoncé
  def call(conn, {:error, {:lesson_changed, revision}}),
    do: conn |> put_status(409) |> json(%{error: "lesson_changed", revision: revision})

  def call(conn, {:error, code}) when is_map_key(@statuses, code),
    do: conn |> put_status(@statuses[code]) |> json(%{error: code})
end
