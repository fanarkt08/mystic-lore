defmodule MlStudio.AI.Deterministic do
  @moduledoc """
  Demo provider with no artificial intelligence: its output only derives from the input, and every text it
  writes carries the label « #{"DEMO MODE — not a real AI"} ».
  """
  @behaviour MlStudio.AI.Provider

  @label "DEMO MODE — not a real AI"

  def label, do: @label

  @impl true
  def name, do: "demo"
  @impl true
  def model, do: nil
  @impl true
  def configured?, do: true
  @impl true
  def external?, do: false
  @impl true
  def images?, do: true

  @impl true
  def generate(%{kind: "outline"} = request) do
    topics = topics(request)
    coding? = get_in(request, [:context, "project", "category"]) == "coding"

    modules =
      for {topic, i} <- Enum.with_index(topics, 1) do
        practice =
          if coding? and i == length(topics),
            do: [lesson("Practice: #{topic}", "coding", "A GroveScript puzzle about #{topic}.")],
            else: []

        %{
          "title" => "Demo module #{i}: #{topic}",
          "lessons" =>
            [
              lesson("Discover #{topic}", "story", "A short story introducing #{topic}."),
              lesson("Quiz: #{topic}", "exercise", "A quick check about #{topic}.")
            ] ++ practice
        }
      end

    {:ok, %{"modules" => modules}}
  end

  def generate(%{kind: "lesson_draft", lesson_kind: kind} = request) do
    topic = request |> topics() |> hd()

    body =
      "#{@label}.\n\nThis draft was produced from your brief about #{topic}. " <>
        "Rewrite it in your own words before publishing."

    {:ok, Map.merge(%{"body" => body}, draft(kind, topic, hash(request)))}
  end

  def generate(%{kind: "feedback"} = request) do
    topic = request |> topics() |> hd()

    {:ok,
     %{
       "explanation" =>
         "#{@label}. The right answer follows from the lesson about #{topic}: " <>
           "re-read the key idea, then compare each choice with it."
     }}
  end

  def generate(_request), do: {:error, :invalid_output}

  @impl true
  def generate_image(request),
    do: {:ok, %{data: svg(request.brief), content_type: "image/svg+xml"}}

  @doc "Geometric SVG derived from the seed (hash bytes → colours and circles), labelled DEMO."
  def svg(seed) do
    <<h1, h2, rest::binary>> = :crypto.hash(:sha256, seed)

    circles =
      for <<x, y, r <- binary_part(rest, 0, 24)>>,
        do:
          ~s|<circle cx="#{rem(x, 320)}" cy="#{rem(y, 180)}" r="#{8 + rem(r, 36)}" fill="hsl(#{div(h2 * 360, 256) + rem(r, 60)},70%,65%)" fill-opacity="0.55"/>|

    ~s|<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 200" width="320" height="200">| <>
      ~s|<rect width="320" height="200" fill="hsl(#{div(h1 * 360, 256)},40%,16%)"/>| <>
      Enum.join(circles) <>
      ~s|<text x="160" y="192" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#ffffff">#{@label}</text></svg>|
  end

  defp lesson(title, kind, summary),
    do: %{"title" => title, "kind" => kind, "summary" => "#{@label}. #{summary}"}

  defp draft("exercise", topic, hash) do
    right = "This lesson is about #{topic}."

    wrong = [
      "This lesson is about cooking.",
      "This lesson has no topic.",
      "This lesson is about the weather."
    ]

    answer = rem(hash, 4)

    %{
      "question" => "Which statement is true? (demo question)",
      "choices" => List.insert_at(wrong, answer, right),
      "answer" => answer,
      "explanation" => "#{@label}. The brief of this lesson is about #{topic}."
    }
  end

  defp draft("coding", _topic, hash) do
    plants = 2 + rem(hash, 9)

    %{
      "plants" => plants,
      "starter" =>
        "# #{@label}\n# Water each of the #{plants} plants (0 to #{plants - 1}) exactly once, with a loop.\nwater(0)\n",
      "hints" => [
        "range(#{plants}) gives 0 to #{plants - 1}.",
        "The loop variable can be passed to water(...).",
        "Write for plant in range(#{plants}): then an indented water(plant)."
      ]
    }
  end

  defp draft(_story, _topic, _hash), do: %{}

  # Topics: the project's objectives when known, else the phrases of the brief.
  defp topics(request) do
    from_context = get_in(request, [:context, "project", "objectives"]) || []

    phrases =
      request.brief
      |> String.split(["\n", ".", ";"], trim: true)
      |> Enum.map(&(&1 |> String.trim() |> String.slice(0, 60)))
      |> Enum.reject(&(&1 == ""))

    case Enum.take(if(from_context != [], do: from_context, else: phrases), 3) do
      [] -> ["your topic"]
      topics -> Enum.map(topics, &String.slice(&1, 0, 60))
    end
  end

  defp hash(request), do: :erlang.phash2({request.brief, request.lesson_kind})
end
