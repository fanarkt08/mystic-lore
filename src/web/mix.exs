defmodule Mystic.MixProject do
  use Mix.Project

  def project do
    [
      app: :web,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      # `mix test --cover` échoue sous 50 % ; les aides de test/support ne sont pas comptées
      test_coverage: [
        summary: [threshold: 50],
        ignore_modules: [~r/(ConnCase|DataCase|Fixtures|TestHelpers|ServiceStub|ApiStub)$/]
      ],
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [mod: {Mystic.Application, []}, extra_applications: [:logger, :runtime_tools]]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ml_shared, path: "../shared"},
      {:phoenix, "~> 1.8.17"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:gettext, "~> 1.0"},
      # fuseaux horaires des membres : base IANA embarquée, compilée avec la bibliothèque (aucun accès réseau)
      {:tz, "~> 0.28"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind web", "esbuild web"],
      "assets.deploy": ["tailwind web --minify", "esbuild web --minify", "phx.digest"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
