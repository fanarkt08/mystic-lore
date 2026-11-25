import Config

# Service interne : une redirection HTTPS forcée casserait les appels entre services et /healthz.
config :logger, level: :info

# Configuration d'exécution (variables d'environnement) : config/runtime.exs.
