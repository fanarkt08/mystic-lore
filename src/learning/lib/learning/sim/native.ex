defmodule MlLearning.Sim.Native do
  @moduledoc """
  Moteur natif optionnel `ml_sim`, lancé dans un processus séparé par `Port` (jamais en NIF).
  Toute sortie anormale ou trop lente renvoie une erreur et l'appelant repasse en Elixir.
  """

  @timeout 500
  @max_output 262_144

  def default_path,
    do: System.get_env("SIM_ENGINE_PATH") || Path.join(:code.priv_dir(:learning), "native/ml_sim")

  def available?(path \\ default_path()), do: File.regular?(path)

  @doc "`{:ok, résultat}` ou `{:error, :absent | :timeout | :output_too_large | {:exit, n} | :invalid_output}`."
  def run(request, opts \\ []) do
    path = Keyword.get(opts, :path, default_path())
    timeout = Keyword.get(opts, :timeout, @timeout)

    with true <- available?(path) || {:error, :absent},
         {:ok, port} <- open(path),
         {:ok, output} <- exchange(port, Jason.encode!(request) <> "\n", timeout),
         {:ok, result} <- decode(output),
         true <- valid?(request, result) || {:error, :invalid_output} do
      {:ok, result}
    end
  end

  defp open(path) do
    env =
      for {name, value} <- child_env(),
          do: {to_charlist(name), if(value, do: to_charlist(value), else: false)}

    {:ok,
     Port.open({:spawn_executable, path}, [:binary, :exit_status, :use_stdio, :hide, env: env])}
  rescue
    _ -> {:error, :absent}
  end

  defp exchange(port, input, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    try do
      Port.command(port, input)
      collect(port, os_pid, [], 0, deadline)
    rescue
      # L'exécutable s'est terminé avant de lire l'entrée : on attend son code de sortie s'il arrive à temps.
      ArgumentError ->
        receive do
          {^port, {:exit_status, status}} -> {:error, {:exit, status}}
        after
          max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, {:exit, :closed}}
        end
    end
  end

  defp collect(port, os_pid, acc, size, deadline) do
    receive do
      {^port, {:data, data}} ->
        size = size + byte_size(data)

        if size > @max_output,
          do: kill(port, os_pid, :output_too_large),
          else: collect(port, os_pid, [acc | data], size, deadline)

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> kill(port, os_pid, :timeout)
    end
  end

  defp kill(port, os_pid, reason) do
    if os_pid,
      do:
        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)],
          stderr_to_stdout: true,
          env: child_env()
        )

    Port.close(port)
    flush(port)
    {:error, reason}
  catch
    _, _ -> {:error, reason}
  end

  # Le moteur et `kill` ne reçoivent aucune variable du serveur, secrets compris : seulement un PATH minimal.
  defp child_env,
    do: [
      {"PATH", "/usr/bin:/bin"}
      | for({name, _} <- System.get_env(), name != "PATH", do: {name, nil})
    ]

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp decode(output) do
    case Jason.decode(output) do
      {:ok, %{} = result} -> {:ok, result}
      _ -> {:error, :invalid_output}
    end
  end

  ## Validation stricte de la sortie

  @orbit_metrics Enum.sort(
                   ~w(bound collided eccentricity energy escaped period r_max r_min revolutions steps_run)
                 )
  @reaction_metrics Enum.sort(
                      ~w(atoms_left atoms_right balanced drift formed limiting lowest_terms theoretical yield_permille)
                    )

  @doc false
  def valid?(%{"model" => "orbit", "steps" => steps}, %{"frames" => frames, "metrics" => m})
      when map_size(m) == 10 do
    Enum.sort(Map.keys(m)) == @orbit_metrics and is_list(frames) and length(frames) in 1..200 and
      Enum.all?(frames, &ints?(&1, 4)) and hd(hd(frames)) == 0 and
      Enum.all?(~w(r_min r_max eccentricity energy), &is_integer(m[&1])) and
      is_integer(m["revolutions"]) and m["revolutions"] >= 0 and
      (is_nil(m["period"]) or is_integer(m["period"])) and
      Enum.all?(~w(bound collided escaped), &is_boolean(m[&1])) and
      is_integer(m["steps_run"]) and m["steps_run"] in 0..steps
  end

  def valid?(
        %{"model" => "reaction", "steps" => steps, "initial" => initial, "atoms" => [a | _]},
        %{"frames" => frames, "metrics" => m}
      )
      when map_size(m) == 9 do
    k = length(a)

    Enum.sort(Map.keys(m)) == @reaction_metrics and is_list(frames) and
      length(frames) == steps + 1 and Enum.all?(frames, &ints?(&1, 1 + length(initial) + k)) and
      Enum.all?(~w(atoms_left atoms_right drift), &ints?(m[&1], k)) and
      is_boolean(m["balanced"]) and is_boolean(m["lowest_terms"]) and
      Enum.all?(~w(theoretical formed yield_permille limiting), &is_integer(m[&1]))
  end

  def valid?(_request, _result), do: false

  defp ints?(list, n), do: is_list(list) and length(list) == n and Enum.all?(list, &is_integer/1)
end
