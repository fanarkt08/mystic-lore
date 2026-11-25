defmodule MlStudio.Projects.Lesson do
  @moduledoc "A lesson of a project, in one of the formats learning can grade."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime]

  @kinds ~w(story exercise coding video simulation minigame)
  @ai_kinds ~w(story exercise coding)
  @xp %{
    "story" => 10,
    "exercise" => 20,
    "coding" => 40,
    "video" => 15,
    "simulation" => 30,
    "minigame" => 25
  }
  # fields of a video lesson that only the media routes may change
  @media_fields ~w(video_id captions)

  schema "lessons" do
    field :position, :integer
    field :title, :string
    field :kind, :string
    field :body, :string, default: ""
    field :xp_reward, :integer, default: 10
    field :content, :map, default: %{}
    field :lock_version, :integer, default: 1
    belongs_to :project, MlStudio.Projects.Project
    belongs_to :module, MlStudio.Projects.CourseModule
    timestamps()
  end

  def kinds, do: @kinds

  @doc "Formats the AI can draft (outline and lesson draft): the others need media or a model."
  def ai_kinds, do: @ai_kinds

  def create_changeset(lesson, attrs) do
    changeset =
      lesson
      |> cast(attrs, [:title, :kind, :body])
      |> update_change(:title, &String.trim/1)
      |> validate_required([:title, :kind])
      |> validate_length(:title, max: 200)
      |> validate_length(:body, max: 20_000)
      |> validate_inclusion(:kind, @kinds)

    case get_field(changeset, :kind) do
      kind when kind in @kinds ->
        {:ok, content} = normalize(kind, %{})
        change(changeset, content: content, xp_reward: @xp[kind])

      _ ->
        changeset
    end
  end

  def update_changeset(lesson, attrs) do
    lesson
    |> cast(attrs, [:title, :body, :xp_reward], empty_values: [nil])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title])
    # empty_values: [nil] keeps "" for the other texts, so a blank title is refused here
    |> validate_change(:title, &if(&2 == "", do: [{&1, "can't be blank"}], else: []))
    |> validate_length(:title, max: 200)
    |> validate_length(:body, max: 20_000)
    |> validate_number(:xp_reward, greater_than_or_equal_to: 0, less_than_or_equal_to: 1_000)
    |> put_content(attrs["content"])
  end

  # A partial content is merged into the current one.
  defp put_content(changeset, nil), do: changeset

  defp put_content(changeset, content) when is_map(content) do
    content =
      if changeset.data.kind == "video", do: Map.drop(content, @media_fields), else: content

    case normalize(changeset.data.kind, Map.merge(changeset.data.content || %{}, content)) do
      {:ok, normalized} -> put_change(changeset, :content, normalized)
      {:error, message} -> add_error(changeset, :content, message)
    end
  end

  defp put_content(changeset, _content), do: add_error(changeset, :content, "is invalid")

  @doc "Known fields of a format, typed and within the storage limits: `{:ok, map} | {:error, message}`."
  def normalize("story", _content), do: {:ok, %{}}

  def normalize("exercise", c) do
    with {:ok, question} <- text(c["question"], 1_000),
         {:ok, choices} <- texts(Map.get(c, "choices", ["", ""]), 10, 500),
         {:ok, answer} <- integer(c["answer"], 0, 9, nil),
         {:ok, explanation} <- text(c["explanation"], 3_000) do
      {:ok,
       %{
         "question" => question,
         "choices" => choices,
         "answer" => answer,
         "explanation" => explanation
       }}
    end
  end

  def normalize("coding", c) do
    with {:ok, plants} <- integer(c["plants"], 0, 99, 3),
         {:ok, starter} <- text(c["starter"], 3_000),
         {:ok, hints} <- texts(c["hints"], 10, 500) do
      {:ok, %{"plants" => plants, "starter" => starter, "hints" => hints}}
    end
  end

  def normalize("video", c) do
    with {:ok, video_id} <- uuid(c["video_id"]),
         {:ok, captions} <- captions(c["captions"]),
         {:ok, transcript} <- text(c["transcript"], 50_000),
         {:ok, duration} <- integer(c["duration_s"], 1, 7_200, nil) do
      {:ok,
       %{
         "video_id" => video_id,
         "captions" => captions,
         "transcript" => transcript,
         "duration_s" => duration
       }}
    end
  end

  def normalize("simulation", c) do
    with {:ok, model} <- one_of(c["model"] || "orbit", ~w(orbit reaction)),
         {:ok, goal} <- text(c["goal_text"], 1_000),
         {:ok, steps} <- integer(c["steps"], 0, 100_000, if(model == "orbit", do: 1_000, else: 6)),
         {:ok, fields} <- model_fields(model, c) do
      {:ok, Map.merge(fields, %{"model" => model, "goal_text" => goal, "steps" => steps})}
    end
  end

  def normalize("minigame", c) do
    with {:ok, game} <- one_of(c["game"] || "sequence", ~w(sequence constellation)),
         {:ok, prompt} <- text(c["prompt"], 1_000),
         {:ok, items} <- texts(c["items"], 20, 300),
         {:ok, stars} <- stars(c["stars"]),
         {:ok, path} <- texts(c["path"], 40, 100) do
      {:ok,
       %{"game" => game, "prompt" => prompt, "items" => items, "stars" => stars, "path" => path}}
    end
  end

  # orbit: two adjustable parameters (launch speed, star mass), fixed distance and time step, objective
  # = eccentricity at most `max_eccentricity` over at least `min_revolutions` orbits.
  defp model_fields("orbit", c) do
    with {:ok, velocity} <-
           range(c["velocity"], %{"min" => 4, "max" => 9, "step" => 0.1, "default" => 5}),
         {:ok, star_mass} <-
           range(c["star_mass"], %{"min" => 0.5, "max" => 2, "step" => 0.1, "default" => 1}),
         {:ok, distance} <- number(c["distance"], 1),
         {:ok, dt} <- number(c["dt"], 0.002),
         {:ok, max_e} <- number(c["max_eccentricity"], 0.03),
         {:ok, min_rev} <- integer(c["min_revolutions"], 0, 100, 1) do
      {:ok,
       %{
         "velocity" => velocity,
         "star_mass" => star_mass,
         "distance" => distance,
         "dt" => dt,
         "max_eccentricity" => max_e,
         "min_revolutions" => min_rev
       }}
    end
  end

  # reaction: species « formula, side, initial amount », coefficients 1..max_coefficient, a chain of
  # `steps` passes at `yield_pct` each, objective = atoms conserved (and smallest whole numbers).
  defp model_fields("reaction", c) do
    with {:ok, species} <- species(c["species"]),
         {:ok, max_c} <- integer(c["max_coefficient"], 1, 99, 8),
         {:ok, yield_pct} <- integer(c["yield_pct"], 0, 100, 90),
         lowest when is_boolean(lowest) <- Map.get(c, "lowest_terms", true) do
      {:ok,
       %{
         "species" => species,
         "max_coefficient" => max_c,
         "yield_pct" => yield_pct,
         "lowest_terms" => lowest
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, "lowest_terms must be true or false"}
    end
  end

  defp range(nil, default), do: {:ok, default}

  defp range(%{} = r, default) do
    Enum.reduce_while(~w(min max step default), {:ok, %{}}, fn key, {:ok, acc} ->
      case number(r[key], default[key]) do
        {:ok, n} -> {:cont, {:ok, Map.put(acc, key, n)}}
        error -> {:halt, error}
      end
    end)
  end

  defp range(_r, _default), do: {:error, "is invalid"}

  defp species(nil), do: {:ok, []}

  defp species(list) when is_list(list) and length(list) <= 10 do
    Enum.reduce_while(list, {:ok, []}, fn s, {:ok, acc} ->
      with %{} <- s,
           {:ok, formula} <- text(s["formula"], 40),
           {:ok, side} <- one_of(s["side"] || "reactant", ~w(reactant product)),
           {:ok, initial} <- number(s["initial"], 0) do
        {:cont, {:ok, acc ++ [%{"formula" => formula, "side" => side, "initial" => initial}]}}
      else
        _ -> {:halt, {:error, "species: formula, side (reactant or product) and initial amount"}}
      end
    end)
  end

  defp species(_list), do: {:error, "should have at most 10 species"}

  defp stars(nil), do: {:ok, []}

  defp stars(list) when is_list(list) and length(list) <= 20 do
    Enum.reduce_while(list, {:ok, []}, fn s, {:ok, acc} ->
      with %{} <- s,
           {:ok, name} <- text(s["name"], 100),
           {:ok, x} <- integer(s["x"], -1_000, 1_000, 0),
           {:ok, y} <- integer(s["y"], -1_000, 1_000, 0) do
        {:cont, {:ok, acc ++ [%{"name" => name, "x" => x, "y" => y}]}}
      else
        _ -> {:halt, {:error, "stars: a name and whole-number x, y for each star"}}
      end
    end)
  end

  defp stars(_list), do: {:error, "should have at most 20 stars"}

  defp captions(nil), do: {:ok, []}

  defp captions(list) when is_list(list) and length(list) <= 6 do
    if Enum.all?(
         list,
         &(is_map(&1) and match?({:ok, id} when is_binary(id), uuid(&1["media_id"])))
       ),
       do: {:ok, Enum.map(list, &Map.take(&1, ["media_id", "lang", "label"]))},
       else: {:error, "is invalid"}
  end

  defp captions(_list), do: {:error, "should have at most 6 caption tracks"}

  defp uuid(nil), do: {:ok, nil}

  defp uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, "is invalid"}
    end
  end

  defp uuid(_id), do: {:error, "is invalid"}

  defp one_of(value, allowed),
    do:
      if(value in allowed,
        do: {:ok, value},
        else: {:error, "must be one of: #{Enum.join(allowed, ", ")}"}
      )

  defp number(nil, default), do: {:ok, default}
  defp number(n, _default) when is_number(n) and abs(n) <= 1.0e9, do: {:ok, n}
  defp number(_n, _default), do: {:error, "must be a number"}

  defp text(nil, _max), do: {:ok, ""}

  defp text(value, max) when is_binary(value) do
    if String.length(value) <= max,
      do: {:ok, value},
      else: {:error, "should be at most #{max} character(s)"}
  end

  defp text(_value, _max), do: {:error, "is invalid"}

  defp texts(nil, _count, _max), do: {:ok, []}

  defp texts(values, count, max) when is_list(values) and length(values) <= count do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case text(value, max) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        error -> {:halt, error}
      end
    end)
  end

  defp texts(_values, count, _max), do: {:error, "should have at most #{count} item(s)"}

  defp integer(nil, _min, _max, default), do: {:ok, default}
  defp integer(n, min, max, _default) when is_integer(n) and n >= min and n <= max, do: {:ok, n}
  defp integer(_n, min, max, _default), do: {:error, "must be an integer from #{min} to #{max}"}
end
