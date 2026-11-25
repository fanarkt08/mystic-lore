defmodule MlStudioWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :studio

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :studio
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # JSON only; an image upload (≤ 2 MB) travels base64-encoded, hence the 3 MB limit.
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    length: 3_000_000,
    json_decoder: Phoenix.json_library()

  plug MlStudioWeb.Router
end
