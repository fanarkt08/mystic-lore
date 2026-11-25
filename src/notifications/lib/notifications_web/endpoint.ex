defmodule MlNotificationsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :notifications

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :notifications
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Corps JSON courts (identifiants et courtes chaînes) : 64 Ko suffisent largement.
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    length: 64_000,
    json_decoder: Phoenix.json_library()

  plug MlNotificationsWeb.Router
end
