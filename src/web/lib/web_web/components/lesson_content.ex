defmodule MysticWeb.LessonContent do
  @moduledoc """
  Renders the text of a story or a quiz, for the lesson page and for the offline package alike.
  """
  use MysticWeb, :html

  @doc "The lesson text, split in paragraphs on blank lines (the drop cap marks a story)."
  attr :lesson, :map, required: true

  def lesson_text(assigns) do
    ~H"""
    <div class={["story space-y-4", @lesson["kind"] == "story" && "story-dropcap"]}>
      <p :for={paragraph <- paragraphs(@lesson["body"])}>{paragraph}</p>
    </div>
    """
  end

  @doc "The quiz question and its choices (radio buttons), or a free answer field when it has no choices."
  attr :content, :map, required: true

  def quiz_fields(assigns) do
    ~H"""
    <fieldset class="space-y-3">
      <legend class="pb-2 text-xl font-medium text-ink">
        {@content["question"] || gettext("Choose the right answer")}
      </legend>
      <%= if is_list(@content["choices"]) and @content["choices"] != [] do %>
        <label
          :for={{choice, i} <- Enum.with_index(@content["choices"])}
          class="choice"
          for={"choice-#{i}"}
        >
          <input type="radio" name="answer" value={i} id={"choice-#{i}"} />
          <span>{choice}</span>
        </label>
      <% else %>
        <.input id="answer" name="answer" value="" label={gettext("Your answer")} />
      <% end %>
    </fieldset>
    """
  end

  @doc "HTML of an offline package: the same text, question and choices as the lesson page."
  def fragment(%{"kind" => kind, "content" => content} = lesson) do
    assigns = %{lesson: lesson, content: content || %{}, quiz: kind == "exercise"}

    ~H"""
    <.lesson_text lesson={@lesson} />
    <.quiz_fields :if={@quiz} content={@content} />
    """
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp paragraphs(text), do: text |> to_string() |> String.split(~r/\n{2,}/, trim: true)
end
