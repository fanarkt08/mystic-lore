defmodule MlShared.MixProject do
  use Mix.Project

  def project do
    [
      app: :ml_shared,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # `mix test --cover` échoue sous 50 % ; les aides de test/support ne sont pas comptées
      test_coverage: [
        summary: [threshold: 50],
        ignore_modules: [~r/(ConnCase|DataCase|Fixtures|TestHelpers|ServiceStub|ApiStub)$/]
      ]
    ]
  end

  def application, do: [mod: {MlShared.Application, []}, extra_applications: [:logger, :crypto]]

  # test/support est aussi compilé par les tests d'accounts et de social
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:plug, "~> 1.16"},
      {:plug_crypto, "~> 2.1"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
