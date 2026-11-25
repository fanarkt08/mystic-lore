defmodule MlStudio.AI.Anthropic do
  @moduledoc """
  Real provider calling the Anthropic Messages API with Req. Without `ANTHROPIC_API_KEY` every call is refused,
  never simulated, and the key is never logged.
  """
  @behaviour MlStudio.AI.Provider
  require Logger
  alias MlStudio.AI.Prompt

  @url "https://api.anthropic.com/v1/messages"
  @version "2026-10-21"
  @fallback_beta "server-side-fallback-2026-07-01"
  # models accepting `fallbacks: "default"`
  @fallback_models ~w(claude-fable-5-2 claude-fable-5-1 claude-opus-5-5 claude-opus-5 claude-sonnet-5-5)

  @impl true
  def name, do: "anthropic"
  @impl true
  def model, do: config(:model)
  @impl true
  def configured?, do: config(:api_key) not in [nil, ""]
  @impl true
  def external?, do: true
  @impl true
  def images?, do: false

  @impl true
  def generate_image(_request), do: {:error, :image_generation_unavailable}

  @impl true
  def generate(request) do
    if configured?() do
      request |> body() |> post() |> output()
    else
      {:error, :not_configured}
    end
  end

  @doc false
  def body(%{kind: kind, lesson_kind: lesson_kind} = request) do
    body = %{
      "model" => model(),
      "max_tokens" => config(:max_tokens),
      "system" => Prompt.system(),
      "messages" => [%{"role" => "user", "content" => Prompt.user(request)}],
      "output_config" => %{
        "effort" => config(:effort),
        "format" => %{"type" => "json_schema", "schema" => Prompt.schema(kind, lesson_kind)}
      }
    }

    if fallbacks?(), do: Map.put(body, "fallbacks", "default"), else: body
  end

  defp post(body) do
    headers =
      [{"x-api-key", config(:api_key)}, {"anthropic-version", @version}] ++
        if(fallbacks?(), do: [{"anthropic-beta", @fallback_beta}], else: [])

    [
      method: :post,
      url: @url,
      json: body,
      headers: headers,
      retry: false,
      connect_options: [timeout: 10_000],
      receive_timeout: config(:receive_timeout)
    ]
    |> Keyword.merge(Application.get_env(:studio, :anthropic_req_options, []))
    |> Req.request()
  end

  defp output({:ok, %Req.Response{status: 200, body: %{"stop_reason" => "refusal"}}}),
    do: {:error, :refused}

  defp output({:ok, %Req.Response{status: 200, body: %{"stop_reason" => "max_tokens"}}}),
    do: {:error, :truncated}

  defp output({:ok, %Req.Response{status: 200, body: %{"content" => content}}})
       when is_list(content) do
    text = for(%{"type" => "text", "text" => t} <- content, do: t) |> Enum.join()

    case Jason.decode(text) do
      {:ok, %{} = json} -> {:ok, json}
      _ -> {:error, :invalid_output}
    end
  end

  defp output({:ok, %Req.Response{status: status}}) do
    Logger.warning("anthropic messages API answered HTTP #{status}")

    cond do
      status == 429 -> {:error, :rate_limited}
      status == 529 -> {:error, :overloaded}
      status >= 500 -> {:error, :provider_unavailable}
      status in [401, 403] -> {:error, :provider_auth}
      true -> {:error, :provider_rejected}
    end
  end

  defp output({:error, %{reason: :timeout}}), do: {:error, :timeout}

  defp output({:error, _exception}) do
    Logger.warning("anthropic messages API unreachable")
    {:error, :provider_unavailable}
  end

  defp fallbacks?, do: model() in @fallback_models

  defp config(key), do: Application.get_env(:studio, :anthropic, []) |> Keyword.get(key)
end
