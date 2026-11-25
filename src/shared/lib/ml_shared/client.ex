defmodule MlShared.Client do
  @moduledoc """
  Client HTTP interne vers les autres services, dont l'URL vient de `<SERVICE>_URL`.
  Seuls les GET sont réessayés : une écriture n'est jamais rejouée automatiquement.
  """
  @defaults %{
    accounts: "http://localhost:4001",
    learning: "http://localhost:4002",
    billing: "http://localhost:4003",
    social: "http://localhost:4004",
    multiplayer: "http://localhost:4005",
    community: "http://localhost:4006",
    studio: "http://localhost:4007",
    notifications: "http://localhost:4008"
  }

  def base_url(service) do
    env = "#{service |> Atom.to_string() |> String.upcase()}_URL"

    System.get_env(env) || get_in(Application.get_env(:ml_shared, :service_urls, %{}), [service]) ||
      Map.fetch!(@defaults, service)
  end

  def caller, do: Application.get_env(:ml_shared, :service_name, "unknown")

  def get(service, path, opts \\ []), do: request(service, :get, path, opts)
  def post(service, path, opts \\ []), do: request(service, :post, path, opts)
  def put(service, path, opts \\ []), do: request(service, :put, path, opts)
  def patch(service, path, opts \\ []), do: request(service, :patch, path, opts)
  def delete(service, path, opts \\ []), do: request(service, :delete, path, opts)

  def request(service, method, path, opts) do
    {as, opts} = Keyword.pop(opts, :as)
    {extra_headers, opts} = Keyword.pop(opts, :headers, [])
    token = MlShared.InternalToken.sign(caller(), as)

    headers =
      merge_headers(
        [{"authorization", "Bearer " <> token}, {"x-ml-service", Atom.to_string(service)}],
        extra_headers
      )

    req_opts =
      [
        method: method,
        base_url: base_url(service),
        url: path,
        headers: headers,
        receive_timeout: 5_000,
        connect_options: [timeout: 2_000],
        retry: if(method == :get, do: :transient, else: false),
        max_retries: 2,
        # appels internes : relances rapides (100 ms puis 200 ms) au lieu du backoff par défaut (1 s, 2 s)
        retry_delay: fn attempt -> 100 * (attempt + 1) end
      ]
      |> Keyword.merge(Application.get_env(:ml_shared, :req_options, []))
      |> Keyword.merge(opts)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: s, body: b}} when s in 200..299 -> {:ok, b}
      {:ok, %Req.Response{status: s, body: b}} -> {:error, {:http, s, b}}
      {:error, _} -> {:error, :unavailable}
    end
  end

  # un en-tête de l'appelant remplace celui de même nom (casse ignorée) au lieu d'être dupliqué
  defp merge_headers(defaults, extra) do
    extra = Enum.map(extra, fn {k, v} -> {k |> to_string() |> String.downcase(), v} end)
    names = MapSet.new(extra, &elem(&1, 0))
    Enum.reject(defaults, fn {k, _} -> MapSet.member?(names, k) end) ++ extra
  end
end
