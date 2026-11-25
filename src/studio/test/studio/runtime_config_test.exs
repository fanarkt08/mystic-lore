defmodule MlStudio.RuntimeConfigTest do
  @moduledoc "Reads `config/runtime.exs` as at boot, for the storage directory."
  # the system's environment variables are changed during a test: synchronous module
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @var "STUDIO_STORAGE_DIR"
  @prod %{
    "DATABASE_URL" => "ecto://user:pass@localhost/ml_studio",
    "SECRET_KEY_BASE" => String.duplicate("k", 64)
  }

  setup do
    saved = Map.new([@var | Map.keys(@prod)], &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  defp read(env, vars) do
    System.delete_env(@var)
    Enum.each(vars, fn {name, value} -> System.put_env(name, value) end)
    @runtime |> Config.Reader.read!(env: env, target: :host) |> get_in([:studio, :storage_dir])
  end

  test "an empty or blank value counts as absent: the default directory of the environment is kept" do
    assert read(:dev, %{}) == nil
    assert read(:dev, %{@var => ""}) == nil
    assert read(:dev, %{@var => "   "}) == nil
  end

  test "an absolute directory is used" do
    assert read(:dev, %{@var => "/var/lib/mysticlore/studio"}) == "/var/lib/mysticlore/studio"
  end

  test "a relative directory is refused: nothing is ever written to the current directory" do
    assert_raise RuntimeError, ~r/STUDIO_STORAGE_DIR must be an absolute path/, fn ->
      read(:dev, %{@var => "images"})
    end
  end

  test "in production, a missing or empty directory refuses to start with a clear message" do
    for value <- [nil, "", " "] do
      vars = if value, do: Map.put(@prod, @var, value), else: @prod

      assert_raise RuntimeError, ~r/STUDIO_STORAGE_DIR is missing or empty/, fn ->
        read(:prod, vars)
      end
    end

    assert read(:prod, Map.put(@prod, @var, "/data/studio")) == "/data/studio"
  end
end
