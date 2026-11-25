defmodule MlLearning.SimNativeTest do
  @moduledoc """
  Moteur natif `ml_sim` : équivalence exacte avec Elixir sur des entrées aléatoires bornées (si le binaire est
  construit), puis délai, plantage, sortie corrompue ou trop longue et absence, qui donnent toutes un repli.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias MlLearning.Sim.{Engine, Native}

  @built Native.available?()
  @moduletag :tmp_dir

  defp orbit(velocity),
    do: %{
      "model" => "orbit",
      "velocity" => velocity,
      "star_mass" => 1_000_000,
      "planet_mass" => 1_000,
      "distance" => 1_000_000,
      "dt" => 2_000,
      "steps" => 300
    }

  # un faux exécutable (script shell) pour simuler les pannes
  defp fake(dir, name, script) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> script <> "\n")
    File.chmod!(path, 0o755)
    path
  end

  describe "equivalence with the Elixir engine" do
    @describetag skip: if(@built, do: false, else: "ml_sim is not built (cargo absent)")

    test "orbit: identical integers on 80 random bounded inputs" do
      :rand.seed(:exsss, {11, 22, 33})

      for _ <- 1..80 do
        request = %{
          "model" => "orbit",
          "velocity" => :rand.uniform(20_000_001) - 1,
          "star_mass" => 99_999 + :rand.uniform(9_900_001),
          "planet_mass" => :rand.uniform(1_000_001) - 1,
          "distance" => 99_999 + :rand.uniform(9_900_001),
          "dt" => 99 + :rand.uniform(19_901),
          "steps" => :rand.uniform(4_000)
        }

        assert {:ok, native} = Native.run(request, timeout: 2_000)
        assert {:ok, ^native, "elixir"} = Engine.elixir(request), inspect(request)
      end
    end

    test "reaction: identical integers on 80 random bounded inputs" do
      :rand.seed(:exsss, {44, 55, 66})

      for _ <- 1..80 do
        n = 1 + :rand.uniform(5)
        k = :rand.uniform(6)
        product = :rand.uniform(n) - 1
        reactant = rem(product + 1, n)

        side = fn
          ^product -> 1
          ^reactant -> -1
          _ -> Enum.random([-1, 1])
        end

        sides = Enum.map(0..(n - 1), side)

        request = %{
          "model" => "reaction",
          "coefficients" => for(_ <- 1..n, do: :rand.uniform(12)),
          "sides" => sides,
          "atoms" => for(_ <- 1..n, do: for(_ <- 1..k, do: :rand.uniform(21) - 1)),
          "initial" => for(_ <- 1..n, do: :rand.uniform(1_000_000_001) - 1),
          "yield_pct" => :rand.uniform(100),
          "steps" => :rand.uniform(100)
        }

        assert {:ok, native} = Native.run(request, timeout: 2_000)
        assert {:ok, ^native, "elixir"} = Engine.elixir(request), inspect(request)
      end
    end

    test "the native engine refuses out-of-bounds input (exit 2) and the engine falls back" do
      assert {:error, {:exit, 2}} = Native.run(orbit(20_000_001))

      log =
        capture_log(fn ->
          assert {:error, :out_of_bounds} = Engine.run(orbit(20_000_001), mode: "native")
        end)

      assert log =~ "falling back to the Elixir engine"
    end

    test "auto mode uses the native engine when it is built" do
      assert {:ok, result, "native"} = Engine.run(orbit(6_300_000), mode: "auto")
      assert {:ok, ^result, "elixir"} = Engine.elixir(orbit(6_300_000))
    end
  end

  describe "failures fall back to Elixir (logged)" do
    test "absent executable", %{tmp_dir: dir} do
      path = Path.join(dir, "missing")
      assert {:error, :absent} = Native.run(orbit(6_300_000), path: path)

      log =
        capture_log(fn ->
          assert {:ok, _, "elixir"} = Engine.run(orbit(6_300_000), mode: "native", path: path)
        end)

      assert log =~ ":absent"
      # auto: the absence is normal (cargo not installed), no warning per request
      assert {:ok, _, "elixir"} = Engine.run(orbit(6_300_000), mode: "auto", path: path)
    end

    test "timeout: the process is killed after the delay", %{tmp_dir: dir} do
      # `exec`: the pid written is the sleeping process itself
      path = fake(dir, "slow", "echo $$ > '#{dir}/pid'; exec sleep 5")
      started = System.monotonic_time(:millisecond)
      assert {:error, :timeout} = Native.run(orbit(6_300_000), path: path, timeout: 300)
      assert System.monotonic_time(:millisecond) - started < 3_000

      # under heavy load the shell may be killed before it wrote its pid: then there is nothing to check
      case File.read(Path.join(dir, "pid")) do
        {:ok, pid} ->
          assert {_, 1} = System.cmd("kill", ["-0", String.trim(pid)], stderr_to_stdout: true)

        {:error, :enoent} ->
          :ok
      end

      log =
        capture_log(fn ->
          assert {:ok, result, "elixir"} =
                   Engine.run(orbit(6_300_000), mode: "native", path: path, timeout: 300)

          assert {:ok, ^result, "elixir"} = Engine.elixir(orbit(6_300_000))
        end)

      assert log =~ ":timeout"
    end

    test "crash (non-zero exit)", %{tmp_dir: dir} do
      path = fake(dir, "crash", "exit 3")
      assert {:error, {:exit, 3}} = Native.run(orbit(6_300_000), path: path)

      assert capture_log(fn ->
               assert {:ok, _, "elixir"} =
                        Engine.run(orbit(6_300_000), mode: "native", path: path)
             end) =~ "{:exit, 3}"
    end

    test "corrupted outputs are refused by the strict validation", %{tmp_dir: dir} do
      outputs = [
        "not json at all",
        ~s({"frames": "garbage", "metrics": {}}),
        # well-formed but a metric is a float instead of an integer
        ~s({"frames":[[0,1,0,1]],"metrics":{"r_min":1.5,"r_max":1,"eccentricity":0,"revolutions":0,"period":null,"energy":0,"bound":true,"collided":false,"escaped":false,"steps_run":0}}),
        # 201 frames
        ~s({"frames":[) <>
          Enum.map_join(0..200, ",", &"[#{&1},0,0,0]") <>
          ~s(],"metrics":{"r_min":1,"r_max":1,"eccentricity":0,"revolutions":0,"period":null,"energy":0,"bound":true,"collided":false,"escaped":false,"steps_run":0}})
      ]

      for {output, i} <- Enum.with_index(outputs) do
        File.write!(Path.join(dir, "out#{i}"), output)
        path = fake(dir, "corrupt#{i}", "read line; cat '#{dir}/out#{i}'")
        assert {:error, :invalid_output} = Native.run(orbit(6_300_000), path: path)
      end

      assert capture_log(fn ->
               assert {:ok, _, "elixir"} =
                        Engine.run(orbit(6_300_000),
                          mode: "native",
                          path: Path.join(dir, "corrupt0")
                        )
             end) =~ ":invalid_output"
    end

    test "an endless output is cut at the size limit", %{tmp_dir: dir} do
      path = fake(dir, "flood", "yes 0123456789 2>/dev/null")

      assert {:error, :output_too_large} =
               Native.run(orbit(6_300_000), path: path, timeout: 2_000)
    end
  end
end
