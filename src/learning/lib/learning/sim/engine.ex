defmodule MlLearning.Sim.Engine do
  @moduledoc """
  Lance une simulation sur le moteur natif s'il est disponible, sinon en Elixir, avec le même résultat.
  """
  require Logger
  alias MlLearning.Sim.{Native, Orbit, Reaction}

  @doc "Exécute une requête canonique et renvoie le résultat avec le moteur utilisé."
  def run(%{"model" => model} = request, opts \\ []) do
    mode = Keyword.get_lazy(opts, :mode, &mode/0)

    if mode == "elixir" do
      elixir(request)
    else
      case Native.run(request, opts) do
        {:ok, result} ->
          {:ok, result, "native"}

        {:error, :absent} when mode == "auto" ->
          once(:absent, fn ->
            Logger.info("ml_sim not built: simulations use the Elixir engine (SIM_ENGINE=auto)")
          end)

          elixir(request)

        {:error, reason} ->
          Logger.warning(
            "ml_sim #{model}: #{inspect(reason)}, falling back to the Elixir engine (SIM_ENGINE=#{mode})"
          )

          elixir(request)
      end
    end
  end

  @doc "Moteur configuré : `\"auto\" | \"native\" | \"elixir\"`."
  def mode do
    case System.get_env("SIM_ENGINE") do
      mode when mode in ["native", "elixir"] -> mode
      _ -> "auto"
    end
  end

  @doc "Calcul de référence en Elixir : `{:ok, résultat, \"elixir\"}` ou `{:error, :out_of_bounds}`."
  def elixir(%{"model" => "orbit"} = request), do: tag(Orbit.run(request))
  def elixir(%{"model" => "reaction"} = request), do: tag(Reaction.run(request))
  def elixir(_request), do: {:error, :out_of_bounds}

  defp tag({:ok, result}), do: {:ok, result, "elixir"}
  defp tag(error), do: error

  defp once(key, fun) do
    unless :persistent_term.get({__MODULE__, key}, false) do
      :persistent_term.put({__MODULE__, key}, true)
      fun.()
    end
  end
end
