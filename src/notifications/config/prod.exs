import Config

# Service interne (jamais exposé au navigateur), appelé en HTTP par les autres services avec un jeton
# interne signé : pas de redirection forcée vers HTTPS, qui casserait ces appels.
config :logger, level: :info
