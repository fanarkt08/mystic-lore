defmodule MlLearning.Video do
  @moduledoc """
  Leçons `video` : médias servis par web, sous-titres et transcription obligatoires.
  Le serveur ne peut pas vérifier le visionnage : il accepte la déclaration du navigateur.
  """

  @types ~w(video/webm video/mp4)
  @threshold 80

  def threshold, do: @threshold

  @doc "Valide un `content` vidéo : `{:ok, content}` ou `{:error, message}`."
  def validate(%{} = c) do
    video = if is_map(c["video"]), do: c["video"], else: %{}

    with {:ok, src} <- path(video["src"], "video.src"),
         true <- video["type"] in @types || {:error, "video.type must be video/webm or video/mp4"},
         {:ok, poster} <- optional_path(video["poster"]),
         {:ok, captions} <- captions(c["captions"]),
         {:ok, transcript} <- transcript(c["transcript"]),
         true <-
           (is_integer(c["duration_s"]) and c["duration_s"] in 1..7200) ||
             {:error, "duration_s must be 1 to 7200 seconds"} do
      {:ok,
       %{
         "video" => %{"src" => src, "type" => video["type"], "poster" => poster},
         "captions" => captions,
         "transcript" => transcript,
         "duration_s" => c["duration_s"]
       }}
    end
  end

  def validate(_content), do: {:error, "content must be an object"}

  defp path(p, field) when is_binary(p) do
    if p =~ ~r"^/media/[A-Za-z0-9_\-./]{1,200}$" and not String.contains?(p, ".."),
      do: {:ok, p},
      else: {:error, "#{field} must be a /media/ path served by web"}
  end

  defp path(_p, field), do: {:error, "#{field} must be a /media/ path served by web"}

  defp optional_path(nil), do: {:ok, nil}
  defp optional_path(p), do: path(p, "video.poster")

  defp captions(list) when is_list(list) and length(list) in 1..6 do
    parsed =
      for c <- list, is_map(c) do
        with true <- is_binary(c["lang"]) and c["lang"] =~ ~r/^[a-z]{2}(-[A-Z]{2})?$/,
             true <- is_binary(c["label"]) and String.length(String.trim(c["label"])) in 1..40,
             {:ok, src} <- path(c["src"], "captions.src") do
          %{"lang" => c["lang"], "label" => String.trim(c["label"]), "src" => src}
        else
          _ -> nil
        end
      end

    if length(parsed) == length(list) and Enum.all?(parsed) and
         length(Enum.uniq_by(parsed, & &1["lang"])) == length(parsed),
       do: {:ok, parsed},
       else: {:error, "captions: 1 to 6 WebVTT tracks with distinct languages (lang, label, src)"}
  end

  defp captions(_list), do: {:error, "captions: at least one WebVTT track is required"}

  defp transcript(t) when is_binary(t) do
    t = String.trim(t)

    if String.length(t) in 1..50_000,
      do: {:ok, t},
      else: {:error, "transcript: the full transcript (1 to 50000 characters) is required"}
  end

  defp transcript(_t), do: {:error, "transcript: the full transcript is required"}

  @doc "Règle de terminaison (paramètres de `POST /complete`) : `:ok` ou `{:error, {:invalid, errors}}`."
  def completion(params) do
    watched = params["watched_percent"]

    cond do
      params["transcript_opened"] == true ->
        :ok

      is_number(watched) and watched >= @threshold and watched <= 100 ->
        :ok

      true ->
        {:error,
         {:invalid,
          %{watched_percent: ["watch at least 80% of the video or open the transcript first"]}}}
    end
  end
end
