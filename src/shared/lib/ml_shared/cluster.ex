defmodule MlShared.Cluster do
  @moduledoc "Connecte ce nœud aux services listés dans `CLUSTER_NODES` et réessaie toutes les 5 s."
  use GenServer

  @interval 5_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :connect)
    {:ok, nil}
  end

  @impl true
  def handle_info(:connect, state) do
    if Node.alive?() do
      for node <- nodes(), node != Node.self(), node not in Node.list(), do: Node.connect(node)
    end

    Process.send_after(self(), :connect, @interval)
    {:noreply, state}
  end

  def nodes do
    (System.get_env("CLUSTER_NODES") || "")
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.to_atom()))
  end
end
