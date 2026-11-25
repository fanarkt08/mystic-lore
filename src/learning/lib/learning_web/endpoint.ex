defmodule MlLearningWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :learning

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :learning
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    length: 100_000,
    json_decoder: Phoenix.json_library()

  plug Plug.Head
  plug MlLearningWeb.Router
end
