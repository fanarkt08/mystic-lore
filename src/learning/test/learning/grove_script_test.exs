defmodule MlLearning.GroveScriptTest do
  use ExUnit.Case, async: true
  alias MlLearning.GroveScript, as: G

  describe "grade/1" do
    test "a loop over range(3) watering the loop variable is correct" do
      for script <- [
            "for plant in range(3):\n    water(plant)\n",
            "for p in range(0, 3):\n\twater(p)",
            "# tend the grove\r\nfor i in range( 3 ) :\r\n  water( i )  # each sapling\r\n\r\n"
          ] do
        assert %{correct: true, trace: [0, 1, 2], feedback: feedback} = G.grade(script)
        assert feedback =~ "exactly once"
      end
    end

    test "watering by hand gives the right trace but is not accepted" do
      assert %{correct: false, trace: [0, 1, 2], feedback: feedback} =
               G.grade("water(0)\nwater(1)\nwater(2)")

      assert feedback =~ "by hand"

      # Une boucle qui arrose des constantes n'est pas « via la boucle » non plus.
      assert %{correct: false, trace: [0, 1, 2]} =
               G.grade("for p in range(1):\n    water(0)\n    water(1)\n    water(2)")
    end

    test "wrong ranges or repeated waterings are not correct" do
      assert %{correct: false, trace: [0, 1]} = G.grade("for p in range(2):\n    water(p)")
      assert %{correct: false, trace: [1, 2, 3]} = G.grade("for p in range(1, 4):\n    water(p)")

      assert %{correct: false, trace: [0, 0, 1, 1, 2, 2]} =
               G.grade("for p in range(3):\n    water(p)\n    water(p)")

      assert %{correct: false, trace: [0, 1, 2, 1]} =
               G.grade("for p in range(3):\n    water(p)\nwater(1)")

      assert %{correct: false, trace: []} = G.grade("for p in range(3, 1):\n    water(p)")
    end

    test "script errors have no trace" do
      assert %{correct: false, trace: nil, feedback: "Script error: " <> _} = G.grade("water(p)")
    end
  end

  describe "run/1 rejects anything outside the grammar (nothing is ever evaluated)" do
    test "arbitrary code" do
      for source <- [
            "System.cmd(\"ls\", [])",
            "File.rm_rf!(\"/\")",
            ":os.cmd(~c\"ls\")",
            "Code.eval_string(\"1 + 1\")",
            "import os",
            "__import__('os').system('ls')",
            "exec(\"water(0)\")",
            "water(0); water(1)",
            "water(1) if True else water(2)",
            "water(0 + 1)",
            "water(-1)",
            "water(\"0\")",
            "water(p)",
            "plant = 2",
            "for p in range(3):\n    os.system('ls')",
            "for p in range(3):\n    water(q)",
            "for p in range(n):\n    water(p)",
            "for p in range(3): water(p)",
            "for p in [0, 1, 2]:\n    water(p)",
            "while True:\n    water(0)",
            "  water(0)"
          ] do
        assert {:error, message} = G.run(source), "should reject: #{inspect(source)}"
        assert is_binary(message)
      end
    end

    test "nested loops" do
      assert {:error, "Nested loops are not supported."} =
               G.run("for a in range(3):\n    for b in range(3):\n        water(a)")
    end

    test "a loop without an indented body" do
      assert {:error, "A loop needs an indented body."} = G.run("for p in range(3):\nwater(0)")
      assert {:error, "A loop needs an indented body."} = G.run("for p in range(3):")
    end
  end

  describe "run/1 limits" do
    test "size: at most 600 bytes" do
      assert {:error, "Script too long" <> _} = G.run(String.duplicate("#", 601))
      assert {:ok, _} = G.run("water(0)" <> String.duplicate(" ", 592))
    end

    test "lines: at most 20 non-blank lines" do
      assert {:ok, events} = G.run(String.duplicate("water(1)\n", 20))
      assert length(events) == 20
      assert {:error, "Too many lines" <> _} = G.run(String.duplicate("water(1)\n", 21))
    end

    test "range: at most 10 iterations" do
      assert {:ok, events} = G.run("for p in range(10):\n    water(p)")
      assert length(events) == 10
      assert {:error, "range is limited" <> _} = G.run("for p in range(11):\n    water(p)")
      assert {:error, "range is limited" <> _} = G.run("for p in range(2, 13):\n    water(p)")
      assert {:error, _} = G.run("for p in range(99999999999999999999):\n    water(p)")
    end

    test "steps: at most 100 waterings" do
      body = String.duplicate("    water(p)\n", 10)
      assert {:ok, events} = G.run("for p in range(10):\n" <> body)
      assert length(events) == 100

      assert {:error, "Too many steps" <> _} =
               G.run("for p in range(10):\n" <> body <> "    water(p)\n")
    end

    test "empty scripts" do
      for source <- ["", "   \n\n", "# only a comment"],
          do: assert({:error, "Write at least one instruction."} = G.run(source))
    end
  end
end
