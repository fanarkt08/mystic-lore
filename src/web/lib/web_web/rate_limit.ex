defmodule MysticWeb.RateLimit do
  @moduledoc """
  Per-IP limits for sensitive form posts. Behind a proxy, `remote_ip` must come from a trusted header.
  """

  # {max requests, window in ms}; a `config :web, :rate_limits` entry with the same key wins.
  @defaults [
    forgot_password: {5, 60_000},
    reset_password: {10, 60_000},
    two_factor: {10, 60_000},
    contact: {10, 3_600_000},
    offline: {120, 60_000}
  ]

  @doc "`:ok` or `{:error, retry_after_seconds}`."
  def check(%Plug.Conn{remote_ip: ip}, bucket), do: check_ip(ip, bucket)

  @doc "Same limit for an IP address read elsewhere (a LiveView's `peer_data`)."
  def check_ip(ip, bucket) do
    {limit, window_ms} =
      Keyword.get(Application.fetch_env!(:web, :rate_limits), bucket) ||
        Keyword.fetch!(@defaults, bucket)

    Mystic.RateLimiter.hit(bucket, ip, limit, window_ms)
  end
end
