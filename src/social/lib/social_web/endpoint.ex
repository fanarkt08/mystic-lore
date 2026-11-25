defmodule MlSocialWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :social

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :social
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # 16 Mo : un message peut porter une pièce jointe en Base64 (PDF de 10 Mo → environ 13,4 Mo)
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    length: 16_000_000,
    json_decoder: Phoenix.json_library()

  plug MlSocialWeb.Router
end
