defmodule MlStudio.AI.Provider do
  @moduledoc "Behaviour of an AI provider, which returns a raw structured output checked afterwards."
  @type request :: %{
          kind: String.t(),
          brief: String.t(),
          lesson_kind: String.t() | nil,
          context: map() | nil
        }

  @callback name() :: String.t()
  @callback model() :: String.t() | nil
  @callback configured?() :: boolean()
  @doc "Does the request leave this server (consent rule)?"
  @callback external?() :: boolean()
  @callback images?() :: boolean()
  @callback generate(request()) :: {:ok, map()} | {:error, atom()}
  @callback generate_image(request()) ::
              {:ok, %{data: binary(), content_type: String.t()}} | {:error, atom()}
end
