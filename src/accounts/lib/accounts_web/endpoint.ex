defmodule MlAccountsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :accounts

  # API JSON interne : ni cookies, ni sessions, ni fichiers statiques.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :accounts
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: {__MODULE__, :log_level, []}

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Head
  plug MlAccountsWeb.Router

  @doc false
  # Le chemin de requête est journalisé en clair : jamais celui qui porte un jeton de réinitialisation.
  def log_level(%Plug.Conn{path_info: ["api", "password-resets", _token | _]}), do: false
  def log_level(_conn), do: :info
end
