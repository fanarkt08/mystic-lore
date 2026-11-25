defmodule MlStudio.WebVTT do
  @moduledoc """
  Strict WebVTT validation for caption tracks. `STYLE` blocks are refused, since their CSS can load remote
  resources.
  """

  @max_bytes 262_144
  @tags ~w(c i b u v lang ruby rt)
  @timing ~r/^((?:\d{2,}:)?[0-5]\d:[0-5]\d\.\d{3})[ \t]+-->[ \t]+((?:\d{2,}:)?[0-5]\d:[0-5]\d\.\d{3})(?:[ \t].*)?$/

  def max_bytes, do: @max_bytes

  @doc "`{:ok, cue_count}` or `{:error, message}`."
  def validate(text) when is_binary(text) and byte_size(text) <= @max_bytes do
    text = String.replace_prefix(text, <<0xEF, 0xBB, 0xBF>>, "")

    with true <- String.valid?(text) || {:error, "must be UTF-8 text"},
         false <- String.contains?(text, <<0>>) && {:error, "must be text"},
         [header | blocks] <- blocks(text),
         true <- header =~ ~r/^WEBVTT([ \t].*)?$/ || {:error, "must start with WEBVTT"},
         {:ok, cues} <- cues(blocks) do
      if cues in 1..2000, do: {:ok, cues}, else: {:error, "must contain 1 to 2000 cues"}
    else
      [] -> {:error, "must start with WEBVTT"}
      error -> error
    end
  end

  def validate(text) when is_binary(text), do: {:error, "must be at most 256 KB"}
  def validate(_text), do: {:error, "must be WebVTT text"}

  # header block, then blocks separated by blank lines
  defp blocks(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split(~r/\n{2,}/, trim: true)
    |> case do
      [header | rest] -> [header |> String.split("\n") |> hd() | rest]
      [] -> []
    end
  end

  defp cues(blocks) do
    Enum.reduce_while(blocks, {:ok, 0}, fn block, {:ok, n} ->
      lines = String.split(block, "\n")

      cond do
        String.starts_with?(block, "NOTE") ->
          {:cont, {:ok, n}}

        String.starts_with?(block, "STYLE") ->
          {:halt, {:error, "STYLE blocks are not allowed"}}

        true ->
          case cue(lines) do
            :ok -> {:cont, {:ok, n + 1}}
            {:error, _} = error -> {:halt, error}
          end
      end
    end)
  end

  defp cue(lines) do
    {timing, payload} =
      case lines do
        [first | rest] ->
          if first =~ "-->", do: {first, rest}, else: {List.first(rest), Enum.drop(rest, 1)}
      end

    with [_, start, stop] <-
           (timing && Regex.run(@timing, timing)) || {:error, "invalid cue timing"},
         true <- ms(start) < ms(stop) || {:error, "a cue must end after it starts"},
         true <-
           (payload != [] and Enum.any?(payload, &(String.trim(&1) != ""))) ||
             {:error, "a cue has no text"},
         true <-
           Enum.all?(payload, &(not String.contains?(&1, "-->"))) || {:error, "invalid cue text"},
         true <- Enum.all?(payload, &tags_ok?/1) || {:error, "only WebVTT cue tags are allowed"} do
      :ok
    end
  end

  defp tags_ok?(line) do
    ~r/<\/?([^>\s.\/]*)[^>]*>/
    |> Regex.scan(line)
    |> Enum.all?(fn [_, name] -> name in @tags or name =~ ~r/^\d/ end)
  end

  defp ms(stamp) do
    parts =
      stamp
      |> String.split(":")
      |> Enum.map(&String.to_float(if &1 =~ ".", do: &1, else: &1 <> ".0"))

    case parts do
      [h, m, s] -> round(((h * 60 + m) * 60 + s) * 1000)
      [m, s] -> round((m * 60 + s) * 1000)
    end
  end
end
