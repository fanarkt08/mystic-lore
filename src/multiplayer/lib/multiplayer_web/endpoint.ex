defmodule MlMultiplayerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :multiplayer

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :multiplayer
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug MlMultiplayerWeb.Router
end
