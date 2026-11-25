defmodule MlLearning do
  @moduledoc """
  Service learning : catalogue (`MlLearning.Catalog`), progression et XP (`MlLearning.Progress`),
  correction (`MlLearning.Grader`, `MlLearning.GroveScript`), droits premium (`MlLearning.Entitlements`).
  """

  @doc "UUID canonique (36 caractères) ou `:error`."
  def cast_uuid(value) when is_binary(value) and byte_size(value) == 36, do: Ecto.UUID.cast(value)
  def cast_uuid(_), do: :error
end
