import Config

# Seulement pour les tests de la bibliothèque : les services ne chargent pas la config d'une dépendance.
if config_env() == :test do
  config :ml_shared, internal_secret: String.duplicate("t", 64)
end
