defmodule MlStudio.AI.Prompt do
  @moduledoc """
  Builds what a provider receives and checks its answer. An external provider only gets the project context
  when both the requester and the owner agreed to share their drafts.
  """
  alias MlStudio.Projects.Lesson

  @doc "`share?`: the provider is not external, or both members agreed."
  def request(generation, project, share?) do
    lesson =
      Enum.find_value(
        project.modules,
        &Enum.find(&1.lessons, fn l -> l.id == generation.lesson_id end)
      )

    %{
      kind: generation.kind,
      brief: generation.brief,
      lesson_kind: if(generation.kind == "feedback", do: "exercise", else: lesson && lesson.kind),
      context: if(share?, do: context(project, lesson))
    }
  end

  defp context(project, lesson) do
    %{
      "project" =>
        project
        |> Map.take([
          :title,
          :summary,
          :objectives,
          :audience,
          :level,
          :category,
          :duration_minutes
        ])
        |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end),
      "outline" =>
        for(
          m <- project.modules,
          do: %{"module" => m.title, "lessons" => Enum.map(m.lessons, & &1.title)}
        ),
      "lesson" =>
        lesson &&
          %{
            "title" => lesson.title,
            "kind" => lesson.kind,
            "body" => lesson.body,
            "content" => lesson.content
          }
    }
  end

  ## Instructions for a language model (MlStudio.AI.Anthropic)

  def system do
    """
    You help an author write a short interactive course for MysticLore, an enchanted academy for \
    curious learners. Write in clear, friendly English for the audience the author describes. \
    Lessons use exactly three formats: "story" (a short narrative that teaches one idea), \
    "exercise" (a multiple-choice quiz with 2 to 6 distinct choices, one correct answer given by \
    its 0-based index, and an explanation of why it is right) and "coding" (a GroveScript puzzle: \
    the learner waters plants numbered 0 to plants-1, each exactly once, with a loop such as \
    `for plant in range(4):` followed by an indented `water(plant)`; plants is 2 to 10; GroveScript \
    has only for/range loops and water(n)). Never use HTML, scripts or links other than http(s). \
    Answer only with the JSON object requested.
    """
  end

  def user(%{kind: kind, brief: brief, lesson_kind: lesson_kind, context: context}) do
    task =
      case kind do
        "outline" ->
          "Propose an outline: 1 to 5 modules of 1 to 4 lessons, each with a title, a format and a one-sentence summary."

        "lesson_draft" ->
          "Write a complete draft of one lesson in the \"#{lesson_kind}\" format."

        "feedback" ->
          "Write a better explanation for the quiz: why the correct answer is right, in 1 to 3 sentences."
      end

    shared =
      if context,
        do:
          "\n\nProject context shared by the authors:\n" <> Jason.encode!(context, pretty: true),
        else: ""

    "#{task}\n\nAuthor's brief for this request:\n#{brief}#{shared}"
  end

  ## Output

  @doc "JSON schema of the expected answer (structured outputs: no numeric/length constraints)."
  def schema("outline", _lesson_kind) do
    lesson =
      object(%{
        "title" => %{"type" => "string"},
        "kind" => %{"type" => "string", "enum" => Lesson.ai_kinds()},
        "summary" => %{"type" => "string"}
      })

    object(%{
      "modules" => %{
        "type" => "array",
        "items" =>
          object(%{
            "title" => %{"type" => "string"},
            "lessons" => %{"type" => "array", "items" => lesson}
          })
      }
    })
  end

  def schema("lesson_draft", "exercise"),
    do:
      object(%{
        "body" => %{"type" => "string"},
        "question" => %{"type" => "string"},
        "choices" => %{"type" => "array", "items" => %{"type" => "string"}},
        "answer" => %{"type" => "integer"},
        "explanation" => %{"type" => "string"}
      })

  def schema("lesson_draft", "coding"),
    do:
      object(%{
        "body" => %{"type" => "string"},
        "plants" => %{"type" => "integer"},
        "starter" => %{"type" => "string"},
        "hints" => %{"type" => "array", "items" => %{"type" => "string"}}
      })

  def schema("lesson_draft", _story), do: object(%{"body" => %{"type" => "string"}})
  def schema("feedback", _lesson_kind), do: object(%{"explanation" => %{"type" => "string"}})

  defp object(properties),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => Map.keys(properties),
      "additionalProperties" => false
    }

  @doc "Checks and normalizes an answer: `{:ok, result} | {:error, :invalid_output}`."
  def validate("outline", _lesson_kind, %{"modules" => [_ | _] = modules}) do
    modules =
      for m <- Enum.take(modules, 20), is_map(m), title = clean(m["title"], 120), title != "" do
        lessons =
          for l <- Enum.take(List.wrap(m["lessons"]), 30),
              is_map(l),
              l["kind"] in Lesson.ai_kinds(),
              title = clean(l["title"], 120),
              title != "",
              do: %{
                "title" => title,
                "kind" => l["kind"],
                "summary" => clean(l["summary"], 2_000)
              }

        %{"title" => title, "lessons" => lessons}
      end

    if modules != [], do: {:ok, %{"modules" => modules}}, else: {:error, :invalid_output}
  end

  def validate("lesson_draft", kind, %{"body" => body} = output) when is_binary(body) do
    content =
      Map.take(output, [
        "question",
        "choices",
        "answer",
        "explanation",
        "plants",
        "starter",
        "hints"
      ])

    with {:ok, content} <- Lesson.normalize(kind, content),
         :ok <- usable(kind, content) do
      {:ok, %{"body" => clean(body, 20_000), "content" => content}}
    else
      _ -> {:error, :invalid_output}
    end
  end

  def validate("feedback", _kind, %{"explanation" => text}) when is_binary(text) and text != "",
    do: {:ok, %{"explanation" => clean(text, 3_000)}}

  def validate(_kind, _lesson_kind, _output), do: {:error, :invalid_output}

  defp usable("exercise", %{"choices" => choices, "answer" => answer}),
    do:
      if(length(choices) in 2..6 and is_integer(answer) and answer < length(choices),
        do: :ok,
        else: :error
      )

  defp usable("coding", %{"plants" => plants}), do: if(plants in 2..10, do: :ok, else: :error)
  defp usable(_kind, _content), do: :ok

  defp clean(text, max) when is_binary(text), do: text |> String.trim() |> String.slice(0, max)
  defp clean(_text, _max), do: ""
end
