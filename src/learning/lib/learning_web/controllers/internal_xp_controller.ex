defmodule MlLearningWeb.InternalXpController do
  @moduledoc """
  XP accordée par un autre service, dont la clé doit commencer par le nom du service appelant.
  """
  use MlLearningWeb, :controller
  alias MlLearning.Gamification

  def create(conn, params) do
    prefix = conn.assigns.caller <> ":"

    with {:ok, user_id} <- MlLearning.cast_uuid(params["user_id"]),
         ref when is_binary(ref) and byte_size(ref) <= 200 <- params["ref_key"],
         true <- String.starts_with?(ref, prefix) and byte_size(ref) > byte_size(prefix),
         amount when is_integer(amount) and amount in 1..500 <- params["amount"] do
      json(conn, %{xp: Gamification.award_xp(user_id, ref, amount)})
    else
      _ ->
        conn
        |> put_status(422)
        |> json(%{
          error: "invalid",
          errors: %{
            xp: [
              "user_id must be a UUID, ref_key must start with \"#{prefix}\", amount must be 1..500"
            ]
          }
        })
    end
  end
end
