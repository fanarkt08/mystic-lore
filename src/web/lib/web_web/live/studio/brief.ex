defmodule MysticWeb.Studio.Brief do
  @moduledoc "The brief form (new project and Brief step) and its conversion to the studio payload."
  use Phoenix.Component
  use Gettext, backend: MysticWeb.Gettext
  import MysticWeb.CoreComponents
  import MysticWeb.Format

  @fields ~w(title summary description objectives prerequisites audience level duration_minutes category cover)a
  def fields, do: @fields

  @doc "Form params of a project (lists one item per line)."
  def params(project) do
    project
    |> Map.take(Enum.map(@fields, &Atom.to_string/1))
    |> Map.update("objectives", "", &Enum.join(&1 || [], "\n"))
    |> Map.update("prerequisites", "", &Enum.join(&1 || [], "\n"))
    |> Map.update("duration_minutes", "", &to_string/1)
  end

  @doc "Studio payload of the form params (blank number → unchanged)."
  def payload(params) do
    %{
      "title" => params["title"],
      "summary" => params["summary"],
      "description" => params["description"],
      "audience" => params["audience"],
      "objectives" => lines(params["objectives"]),
      "prerequisites" => lines(params["prerequisites"]),
      "level" => params["level"],
      "category" => params["category"],
      "cover" => params["cover"],
      "duration_minutes" => integer(params["duration_minutes"])
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  def lines(nil), do: nil

  def lines(text),
    do: text |> String.split(~r/\R/) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  def integer(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  attr :form, :any, required: true
  attr :disabled, :boolean, default: false

  def brief_fields(assigns) do
    ~H"""
    <fieldset class="space-y-5" disabled={@disabled}>
      <.input
        field={@form[:title]}
        label={gettext("Title")}
        maxlength="200"
        required
        phx-debounce="800"
      />
      <.input
        field={@form[:objectives]}
        type="textarea"
        rows="3"
        label={gettext("Learning objectives")}
        hint={gettext("One per line: what learners will be able to do (1 to 10).")}
        phx-debounce="800"
      />
      <.input
        field={@form[:audience]}
        label={gettext("Audience")}
        hint={gettext("For whom? For example: curious beginners, ages 10 and up.")}
        maxlength="300"
        phx-debounce="800"
      />
      <div class="grid gap-5 sm:grid-cols-2">
        <.input
          field={@form[:level]}
          type="select"
          label={gettext("Level")}
          options={for l <- ~w(beginner intermediate advanced), do: {difficulty_label(l), l}}
        />
        <.input
          field={@form[:duration_minutes]}
          type="number"
          label={gettext("Duration (minutes)")}
          phx-debounce="800"
        />
        <.input
          field={@form[:category]}
          type="select"
          label={gettext("Category")}
          options={for c <- ~w(coding science humanities creative), do: {category_label(c), c}}
        />
        <.input
          field={@form[:cover]}
          type="select"
          label={gettext("Cover")}
          options={[
            {gettext("Enchanted forest"), "forest"},
            {gettext("Starlit observatory"), "observatory"},
            {gettext("Alchemy workshop"), "alchemy"},
            {gettext("Ancient archive"), "archive"}
          ]}
        />
      </div>
      <.input
        field={@form[:summary]}
        type="textarea"
        rows="2"
        label={gettext("Summary")}
        hint={gettext("Shown on the adventure card (300 characters at most to publish).")}
        maxlength="1000"
        phx-debounce="800"
      />
      <.input
        field={@form[:prerequisites]}
        type="textarea"
        rows="2"
        label={gettext("Prerequisites (optional)")}
        hint={gettext("One per line.")}
        phx-debounce="800"
      />
      <.input
        field={@form[:description]}
        type="textarea"
        rows="4"
        label={gettext("Description (optional)")}
        maxlength="20000"
        phx-debounce="800"
      />
    </fieldset>
    """
  end
end
