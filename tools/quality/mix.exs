defmodule MlQuality.MixProject do
  use Mix.Project

  # Credo, Sobelow et mix_audit vivent dans un projet à part, car Phoenix refuse les requêtes quand le mix.lock
  # d'un service change pendant qu'il tourne. À lancer depuis ce dossier avec MIX_ENV=test.
  def project do
    [
      app: :ml_quality,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  # Outils d'analyse seulement : environnement de test, jamais démarrés (runtime: false).
  defp deps do
    [
      {:credo, "~> 1.7", only: :test, runtime: false},
      {:sobelow, "~> 0.19.0", only: :test, runtime: false},
      {:mix_audit, "~> 2.1", only: :test, runtime: false}
    ]
  end
end
