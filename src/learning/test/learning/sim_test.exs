defmodule MlLearning.SimTest do
  use ExUnit.Case, async: true
  alias MlLearning.{Fixtures, Sim}
  alias MlLearning.Sim.{Engine, Orbit, Reaction}

  defp orbit(velocity, opts \\ []) do
    Map.merge(
      %{
        "velocity" => velocity,
        "star_mass" => 1_000_000,
        "planet_mass" => 1_000,
        "distance" => 1_000_000,
        "dt" => 2_000,
        "steps" => 1_000
      },
      Map.new(opts, fn {k, v} -> {Atom.to_string(k), v} end)
    )
  end

  defp water(coefficients, steps \\ 6),
    do: %{
      "coefficients" => coefficients,
      "sides" => [-1, -1, 1],
      "atoms" => [[2, 0], [0, 2], [2, 1]],
      "initial" => [10_000_000, 5_000_000, 0],
      "yield_pct" => 90,
      "steps" => steps
    }

  describe "orbit engine" do
    test "is deterministic and returns the reference integers (same as the native engine)" do
      assert {:ok, a} = Orbit.run(orbit(6_300_000))
      assert {:ok, ^a} = Orbit.run(orbit(6_300_000))

      assert %{
               "eccentricity" => 4_394,
               "revolutions" => 1,
               "period" => 1_008_000,
               "r_min" => 1_000_000,
               "r_max" => 1_008_827,
               "bound" => true,
               "collided" => false,
               "escaped" => false,
               "steps_run" => 1_000
             } = a["metrics"]

      assert length(a["frames"]) == 168
      assert [[0, 1_000_000, 0, 1_000_000] | _] = a["frames"]
    end

    test "never returns more than 200 sampled frames, first at t = 0 and last at the final step" do
      for steps <- [1, 197, 198, 199, 396, 397, 1_000, 19_999, 20_000] do
        {:ok, %{"frames" => frames}} = Orbit.run(orbit(6_300_000, steps: steps, dt: 100))
        assert length(frames) <= 200, "#{steps} steps"
        assert hd(hd(frames)) == 0
        assert hd(List.last(frames)) == steps * 100
      end
    end

    test "a planet without speed falls into its star; a fast one escapes" do
      {:ok, %{"metrics" => fall}} = Orbit.run(orbit(0, dt: 100, steps: 5_000))
      assert fall["collided"] and fall["steps_run"] < 5_000

      {:ok, %{"metrics" => away}} = Orbit.run(orbit(15_000_000, dt: 20_000, steps: 20_000))
      assert away["escaped"] and not away["bound"]
    end

    test "refuses anything out of bounds, never computes unbounded work" do
      assert {:error, :out_of_bounds} = Orbit.run(orbit(20_000_001))
      assert {:error, :out_of_bounds} = Orbit.run(orbit(6_300_000, steps: 20_001))
      assert {:error, :out_of_bounds} = Orbit.run(orbit(6_300_000, dt: 99))
      assert {:error, :out_of_bounds} = Orbit.run(orbit(6.3))
      assert {:error, :out_of_bounds} = Orbit.run(Map.delete(orbit(6_300_000), "distance"))
    end
  end

  describe "reaction engine" do
    test "atoms are conserved only by a balanced equation" do
      {:ok, %{"frames" => frames, "metrics" => ok}} = Reaction.run(water([2, 1, 2]))
      assert ok["balanced"] and ok["lowest_terms"] and ok["drift"] == [0, 0]
      assert length(frames) == 7
      assert Enum.uniq(Enum.map(frames, &Enum.take(&1, -2))) == [[20_000_000, 10_000_000]]
      assert %{"formed" => 9_999_990, "theoretical" => 10_000_000, "yield_permille" => 999} = ok

      {:ok, %{"metrics" => bad}} = Reaction.run(water([1, 1, 1]))
      refute bad["balanced"]
      assert bad["drift"] == [0, -4_999_995]
      assert bad["limiting"] == 1

      {:ok, %{"metrics" => double}} = Reaction.run(water([4, 2, 4]))
      assert double["balanced"] and not double["lowest_terms"]
    end

    test "refuses out-of-bounds inputs" do
      assert {:error, :out_of_bounds} = Reaction.run(water([13, 1, 2]))
      assert {:error, :out_of_bounds} = Reaction.run(water([2, 1, 2], 101))

      assert {:error, :out_of_bounds} =
               Reaction.run(%{water([2, 1, 2]) | "sides" => [-1, -1, -1]})

      assert {:error, :out_of_bounds} =
               Reaction.run(%{water([2, 1, 2]) | "initial" => [-1, 0, 0]})
    end
  end

  describe "lesson configuration" do
    test "the fixtures' orbit and reaction lessons are valid; the criterion is kept apart" do
      assert %{content: %{"model" => "orbit", "params" => %{"velocity" => v}}, solution: s} =
               Fixtures.orbit_lesson()

      assert %{"label" => "Launch speed", "unit" => "AU/yr", "min" => 4.0} = v
      assert s == %{"max_eccentricity" => 0.03, "min_revolutions" => 1}

      assert %{content: %{"species" => [%{"atoms" => %{"H" => 2}} | _]}} =
               Fixtures.reaction_lesson()
    end

    test "refuses unknown models, parameters outside the model's hard bounds and off-grid defaults" do
      base = Fixtures.orbit_lesson().content
      velocity = base["params"]["velocity"]

      assert {:error, "model must be" <> _} = Sim.validate(%{base | "model" => "fusion"}, %{})

      for bad <- [
            %{velocity | "max" => 25.0},
            %{velocity | "default" => 5.05},
            %{velocity | "step" => 0.0},
            %{velocity | "min" => 9.0}
          ] do
        content = put_in(base, ["params", "velocity"], bad)

        assert {:error, "params.velocity" <> _} =
                 Sim.validate(content, %{"max_eccentricity" => 0.03})
      end

      assert {:error, "params.warp" <> _} =
               Sim.validate(put_in(base, ["params", "warp"], velocity), %{
                 "max_eccentricity" => 0.03
               })

      assert {:error, "max_eccentricity" <> _} = Sim.validate(base, %{})
      assert {:error, "goal_text" <> _} = Sim.validate(Map.delete(base, "goal_text"), %{})
    end

    test "parses simple chemical formulas only" do
      assert {:ok, %{"C" => 2, "H" => 6, "O" => 1}} = Sim.parse_formula("C2H5OH")
      assert {:ok, %{"Na" => 1, "Cl" => 1}} = Sim.parse_formula("NaCl")
      assert :error = Sim.parse_formula("Ca(OH)2")
      assert :error = Sim.parse_formula("h2o")
      assert :error = Sim.parse_formula("H99")
    end
  end

  describe "learner parameters" do
    setup do: %{content: Fixtures.orbit_lesson().content}

    test "missing values take the defaults; the request only holds bounded integers", %{
      content: content
    } do
      assert {:ok, request, %{"velocity" => 5.0, "star_mass" => 1.0}} =
               Sim.request(content, %{})

      assert request == %{
               "model" => "orbit",
               "velocity" => 5_000_000,
               "star_mass" => 1_000_000,
               "planet_mass" => 1_000,
               "distance" => 1_000_000,
               "dt" => 2_000,
               "steps" => 1_000
             }
    end

    test "out of bounds, off the grid, unknown or not a number → 422 errors per field", %{
      content: content
    } do
      assert {:error, {:invalid, %{"params.velocity" => ["must be between 4.0 and 9.0"]}}} =
               Sim.request(content, %{"velocity" => 50})

      assert {:error, {:invalid, %{"params.velocity" => ["must be 4.0 plus a multiple of 0.1"]}}} =
               Sim.request(content, %{"velocity" => 6.25})

      assert {:error, {:invalid, %{"params.warp" => _}}} =
               Sim.request(content, %{"warp" => 1})

      assert {:error, {:invalid, %{"params.star_mass" => ["must be a number"]}}} =
               Sim.request(content, %{"star_mass" => "1.0"})

      assert {:error, {:invalid, %{"params.velocity" => _}}} =
               Sim.request(content, %{"velocity" => 1.0e300})
    end

    test "simulate presents ≤ 200 frames, columns, metrics and a description", %{content: content} do
      assert {:ok, response, _} = Sim.simulate(content, %{"velocity" => 6.3}, mode: "elixir")

      assert %{
               "model" => "orbit",
               "engine" => "elixir",
               "columns" => [%{"key" => "t", "unit" => "yr"} | _],
               "plot" => %{"type" => "path"},
               "metrics" => %{"eccentricity" => 0.004394, "revolutions" => 1, "period" => 1.008},
               "description" => description
             } = response

      assert length(response["frames"]) in 1..200
      assert hd(response["frames"]) == [0.0, 1.0, 0.0, 1.0]
      assert description =~ "completed 1 full orbit"
    end
  end

  describe "objectives (server-side criterion)" do
    test "orbit: only a closed, nearly circular orbit meets the goal" do
      %{content: c, solution: s} = Fixtures.orbit_lesson()

      run = fn values ->
        {:ok, _, result} = Sim.simulate(c, values, mode: "elixir")
        result
      end

      assert %{correct: true} = Sim.evaluate(c, s, run.(%{"velocity" => 6.3}))
      assert %{correct: true} = Sim.evaluate(c, s, run.(%{"velocity" => 6.2}))

      assert %{correct: false, feedback: "The orbit closes" <> _} =
               Sim.evaluate(c, s, run.(%{"velocity" => 6.5}))

      assert %{correct: false, feedback: feedback} =
               Sim.evaluate(c, s, run.(%{"velocity" => 9.0}))

      assert feedback =~ "escaped"
      # a heavier sun needs a faster launch
      assert %{correct: true} =
               Sim.evaluate(c, s, run.(%{"velocity" => 7.7, "star_mass" => 1.5}))
    end

    test "reaction: balanced in lowest terms only" do
      %{content: c, solution: s} = Fixtures.reaction_lesson()

      run = fn values ->
        {:ok, _, result} = Sim.simulate(c, values, mode: "elixir")
        result
      end

      coefs = fn h2, o2, h2o -> %{"h2" => h2, "o2" => o2, "h2o" => h2o} end

      assert %{correct: true} = Sim.evaluate(c, s, run.(coefs.(2, 1, 2)))

      assert %{
               correct: false,
               feedback: "Not balanced yet: O has 2 atom(s) on the left and 1" <> _
             } =
               Sim.evaluate(c, s, run.(coefs.(1, 1, 1)))

      assert %{correct: false, feedback: "Every atom is conserved, but" <> _} =
               Sim.evaluate(c, s, run.(coefs.(4, 2, 4)))

      {:ok, response, _} = Sim.simulate(c, coefs.(2, 1, 2), mode: "elixir")
      assert response["metrics"]["atoms_left"] == %{"H" => 4, "O" => 2}
      assert response["description"] =~ "2 H2 + O2 → 2 H2O"
      assert [%{"key" => "pass"}, %{"key" => "h2"} | _] = response["columns"]
    end

    test "every feedback carries a stable code and its parameters, for the client's translation" do
      %{content: c, solution: s} = Fixtures.reaction_lesson()

      run = fn content, values ->
        {:ok, _, result} = Sim.simulate(content, values, mode: "elixir")
        result
      end

      coefs = fn h2, o2, h2o -> %{"h2" => h2, "o2" => o2, "h2o" => h2o} end

      assert %{feedback_code: "reaction_balanced", feedback_params: %{}} =
               Sim.evaluate(c, s, run.(c, coefs.(2, 1, 2)))

      assert %{
               feedback_code: "reaction_unbalanced",
               feedback_params: %{"element" => "O", "left" => 2, "right" => 1}
             } = Sim.evaluate(c, s, run.(c, coefs.(1, 1, 1)))

      assert %{feedback_code: "reaction_common_factor", feedback_params: %{}} =
               Sim.evaluate(c, s, run.(c, coefs.(4, 2, 4)))

      %{content: o, solution: os} = Fixtures.orbit_lesson()

      assert %{
               feedback_code: "orbit_stable",
               feedback_params: %{"eccentricity" => _, "period" => _}
             } =
               Sim.evaluate(o, os, run.(o, %{"velocity" => 6.3}))

      assert %{feedback_code: "orbit_elongated", feedback_params: %{"eccentricity" => _}} =
               Sim.evaluate(o, os, run.(o, %{"velocity" => 6.5}))

      assert %{feedback_code: "orbit_escaped"} =
               Sim.evaluate(o, os, run.(o, %{"velocity" => 9.0}))
    end
  end

  test "the engine selection: elixir mode never starts the native executable" do
    assert {:ok, _, "elixir"} =
             Engine.run(orbit(6_300_000) |> Map.put("model", "orbit"),
               mode: "elixir",
               path: "/nonexistent/ml_sim"
             )
  end
end
