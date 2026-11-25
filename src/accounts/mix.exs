defmodule MlAccounts.MixProject do
  use Mix.Project

  def project do
    [
      app: :accounts,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      # `mix test --cover` échoue sous 50 % ; les aides de test/support ne sont pas comptées
      test_coverage: [
        summary: [threshold: 50],
        ignore_modules: [~r/(ConnCase|DataCase|Fixtures|TestHelpers|ServiceStub|ApiStub)$/]
      ],
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {MlAccounts.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  # ../shared/test/support : images construites pour les tests (MlShared.ImageFixtures), sans copie
  defp elixirc_paths(:test),
    do: ["lib", "test/support", Path.expand("../shared/test/support", __DIR__)]

  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:ml_shared, path: "../shared"},
      {:bcrypt_elixir, "~> 3.0"},
      # 2FA : codes TOTP (RFC 6238) et QR code SVG de l'URI otpauth://
      {:nimble_totp, "~> 1.0"},
      {:eqrcode, "~> 0.2"},
      # fuseau horaire des préférences : nom IANA validé (base embarquée, aucun accès réseau)
      {:tz, "~> 0.28"},
      # export des données (assemblage asynchrone, relances) et exécuteur des suppressions de compte
      {:oban, "~> 2.19"},
      {:phoenix, "~> 1.8.17"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
