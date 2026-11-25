defmodule MlBillingWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :billing

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :billing
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # The raw body of POST /webhooks/stripe is kept for the Stripe signature check.
  plug Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    body_reader: {MlBillingWeb.BodyReader, :read_body, []},
    json_decoder: Phoenix.json_library()

  plug MlBillingWeb.Router
end
