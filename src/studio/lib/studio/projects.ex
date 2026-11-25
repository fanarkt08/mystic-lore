defmodule MlStudio.Projects do
  @moduledoc """
  Projects, modules, lessons, collaborators and versions. Anybody but the owner and the collaborators,
  moderators included, gets `:not_found`: drafts are never disclosed.
  """
  import Ecto.Query
  alias Ecto.Changeset
  alias MlStudio.{Events, Repo, Services}
  alias MlStudio.Projects.{Collaborator, CourseModule, Lesson, Project, Version}

  @locked ~w(submitted approved)
  @max_modules 20
  @max_lessons 30
  @max_collaborators 10

  ## Access

  @doc "`{:ok, project, role}` when `user_id` may `need` (`:view | :edit | :owner`) the project."
  def access(user_id, project_id, need, opts \\ []) do
    with {:ok, id} <- Ecto.UUID.cast(project_id),
         %Project{} = project <- fetch(id, opts[:lock]),
         role when is_binary(role) <- role(project, user_id) do
      if allowed?(role, need), do: {:ok, project, role}, else: {:error, :forbidden}
    else
      _ -> {:error, :not_found}
    end
  end

  defp fetch(id, true), do: Repo.one(from p in Project, where: p.id == ^id, lock: "FOR UPDATE")
  defp fetch(id, _lock), do: Repo.get(Project, id)

  @doc "`\"owner\" | \"editor\" | \"viewer\" | nil`."
  def role(%Project{owner_id: owner_id}, owner_id), do: "owner"

  def role(%Project{id: id}, user_id),
    do:
      Repo.one(
        from c in Collaborator,
          where: c.project_id == ^id and c.user_id == ^user_id,
          select: c.role
      )

  defp allowed?(_role, :view), do: true
  defp allowed?(role, :edit), do: role in ["owner", "editor"]
  defp allowed?(role, :owner), do: role == "owner"

  @doc "Content, collaborators and images of a project, in order."
  def load(%Project{} = project),
    do: Repo.preload(project, [:collaborators, :images, :media, modules: :lessons], force: true)

  ## Projects

  @doc "Projects owned by the member, and those shared with them: `[{project, role, counts}]`."
  def list(user_id) do
    owned =
      Repo.all(from p in Project, where: p.owner_id == ^user_id, order_by: [desc: p.updated_at])

    shared =
      Repo.all(
        from p in Project,
          join: c in Collaborator,
          on: c.project_id == p.id and c.user_id == ^user_id,
          order_by: [desc: p.updated_at],
          select: {p, c.role}
      )

    ids = Enum.map(owned, & &1.id) ++ Enum.map(shared, &elem(&1, 0).id)
    modules = counts(CourseModule, ids)
    lessons = counts(Lesson, ids)

    with_counts = fn {p, role} ->
      {p, role, {Map.get(modules, p.id, 0), Map.get(lessons, p.id, 0)}}
    end

    %{owned: Enum.map(owned, &with_counts.({&1, "owner"})), shared: Enum.map(shared, with_counts)}
  end

  defp counts(schema, ids),
    do:
      Map.new(
        Repo.all(
          from x in schema,
            where: x.project_id in ^ids,
            group_by: x.project_id,
            select: {x.project_id, count(x.id)}
        )
      )

  def create(user_id, attrs),
    do: %Project{owner_id: user_id} |> Project.brief_changeset(attrs) |> Repo.insert()

  def get(user_id, project_id) do
    with {:ok, project, role} <- access(user_id, project_id, :view),
         do: {:ok, load(project), role}
  end

  @doc "Autosave of the brief (`lock_version` required)."
  def update_brief(user_id, project_id, attrs) do
    change_content(user_id, project_id, :edit, fn project, _role ->
      with {:ok, version} <- lock_version(attrs) do
        %{project | lock_version: version}
        |> Project.brief_changeset(attrs)
        |> save_locked(fn -> Repo.get!(Project, project.id) end)
      end
    end)
    |> case do
      {:ok, project} -> {:ok, Repo.get!(Project, project.id)}
      error -> error
    end
  end

  @doc "Deletes a project (owner, not during review) and its image files."
  def delete(user_id, project_id) do
    Repo.transact(fn ->
      with {:ok, project, _role} <- access(user_id, project_id, :owner, lock: true),
           :ok <- editable(project) do
        Repo.delete(project)
      end
    end)
    |> case do
      {:ok, project} ->
        MlStudio.Images.remove_files(project.id)
        {:ok, project}

      error ->
        error
    end
  end

  ## Modules

  def add_module(user_id, project_id, attrs) do
    change_content(user_id, project_id, :edit, fn project, _role ->
      siblings = from m in CourseModule, where: m.project_id == ^project.id

      if Repo.aggregate(siblings, :count) >= @max_modules do
        {:error, :too_many_modules}
      else
        %CourseModule{project_id: project.id, position: next_position(siblings)}
        |> CourseModule.changeset(attrs)
        |> Repo.insert()
      end
    end)
  end

  def update_module(user_id, project_id, module_id, attrs) do
    change_content(user_id, project_id, :edit, fn project, _role ->
      with {:ok, module} <- child(CourseModule, project, module_id),
           {:ok, version} <- lock_version(attrs) do
        %{module | lock_version: version}
        |> CourseModule.changeset(attrs)
        |> save_locked(fn -> Repo.get!(CourseModule, module.id) end)
      end
    end)
  end

  def delete_module(user_id, project_id, module_id) do
    change_content(user_id, project_id, :edit, fn project, _role ->
      with {:ok, module} <- child(CourseModule, project, module_id) do
        Repo.delete!(module)
        renumber(from(m in CourseModule, where: m.project_id == ^project.id))
        {:ok, :deleted}
      end
    end)
  end

  @doc "New order of all the modules (keyboard reordering sends the full list)."
  def reorder_modules(user_id, project_id, ids) do
    change_content(user_id, project_id, :edit, fn project, _role ->
      siblings = from m in CourseModule, where: m.project_id == ^project.id

      with :ok <- reorder(siblings, ids, :module_ids),
           do: {:ok, Repo.all(from m in siblings, order_by: m.position)}
    end)
  end

  ## Lessons

  def add_lesson(user_id, project_id, module_id, attrs) do
    change_content(user_id, project_id, :edit, fn project, _role ->
      with {:ok, module} <- child(CourseModule, project, module_id) do
        siblings = from l in Lesson, where: l.module_id == ^module.id

        if Repo.aggregate(siblings, :count) >= @max_lessons do
          {:error, :too_many_lessons}
        else
          %Lesson{project_id: project.id, module_id: module.id, position: next_position(siblings)}
          |> Lesson.create_changeset(attrs)
          |> Repo.insert()
        end
      end
    end)
  end

  @doc "Autosave of a lesson (`lock_version` required); a partial `content` is merged."
  def update_lesson(user_id, project_id, lesson_id, attrs) do
    change_content(user_id, project_id, :edit, fn project, _role ->
      with {:ok, lesson} <- child(Lesson, project, lesson_id),
           {:ok, version} <- lock_version(attrs) do
        %{lesson | lock_version: version}
        |> Lesson.update_changeset(attrs)
        |> save_locked(fn -> Repo.get!(Lesson, lesson.id) end)
      end
    end)
  end

  def delete_lesson(user_id, project_id, lesson_id) do
    change_content(user_id, project_id, :edit, fn project, _role ->
      with {:ok, lesson} <- child(Lesson, project, lesson_id) do
        Repo.delete!(lesson)
        renumber(from(l in Lesson, where: l.module_id == ^lesson.module_id))
        {:ok, :deleted}
      end
    end)
  end

  def reorder_lessons(user_id, project_id, module_id, ids) do
    change_content(user_id, project_id, :edit, fn project, _role ->
      with {:ok, module} <- child(CourseModule, project, module_id),
           siblings = from(l in Lesson, where: l.module_id == ^module.id),
           :ok <- reorder(siblings, ids, :lesson_ids),
           do: {:ok, Repo.all(from l in siblings, order_by: l.position)}
    end)
  end

  @doc "Lesson of the project (`{:error, :not_found}` otherwise)."
  def lesson(%Project{} = project, lesson_id), do: child(Lesson, project, lesson_id)

  ## Collaborators (owner only; a collaborator may leave)

  def invite(user_id, project_id, attrs) do
    with {:ok, project, _role} <- access(user_id, project_id, :owner),
         {:ok, role} <- collaborator_role(attrs["role"] || "editor"),
         {:ok, username} <- username(attrs["username"]),
         {:ok, member} <- Services.user_by_username(username),
         :ok <- if(member["id"] == user_id, do: {:error, :self}, else: :ok),
         :ok <- not_blocked(user_id, member["id"]),
         :ok <-
           below(from(c in Collaborator, where: c.project_id == ^project.id), @max_collaborators) do
      %Collaborator{
        project_id: project.id,
        user_id: member["id"],
        username: member["username"],
        role: role,
        invited_by: user_id
      }
      |> Changeset.change()
      |> Changeset.unique_constraint([:project_id, :user_id])
      |> Repo.insert()
      |> case do
        {:ok, collaborator} ->
          Events.project_changed(project, user_id)
          {:ok, collaborator}

        {:error, _changeset} ->
          {:error, :already_collaborator}
      end
    end
  end

  def update_collaborator(user_id, project_id, member_id, attrs) do
    with {:ok, project, _role} <- access(user_id, project_id, :owner),
         {:ok, role} <- collaborator_role(attrs["role"]),
         {:ok, collaborator} <- collaborator(project, member_id) do
      collaborator = collaborator |> Changeset.change(role: role) |> Repo.update!()
      Events.project_changed(project, user_id)
      {:ok, collaborator}
    end
  end

  def remove_collaborator(user_id, project_id, member_id) do
    with {:ok, project, role} <- access(user_id, project_id, :view),
         :ok <- if(role == "owner" or member_id == user_id, do: :ok, else: {:error, :forbidden}),
         {:ok, collaborator} <- collaborator(project, member_id) do
      Repo.delete!(collaborator)
      Events.project_changed(project, user_id)
      {:ok, :deleted}
    end
  end

  defp collaborator(project, member_id) do
    with {:ok, id} <- Ecto.UUID.cast(member_id),
         %Collaborator{} = c <- Repo.get_by(Collaborator, project_id: project.id, user_id: id) do
      {:ok, c}
    else
      _ -> {:error, :not_found}
    end
  end

  defp collaborator_role(role) when role in ["editor", "viewer"], do: {:ok, role}
  defp collaborator_role(_role), do: {:error, {:invalid, %{role: ["is invalid"]}}}

  defp username(name) when is_binary(name) do
    name = name |> String.trim() |> String.trim_leading("@") |> String.downcase()

    if name =~ ~r/^[a-z0-9_]{3,24}$/,
      do: {:ok, name},
      else: {:error, {:invalid, %{username: ["has invalid format"]}}}
  end

  defp username(_name), do: {:error, {:invalid, %{username: ["can't be blank"]}}}

  defp not_blocked(a, b) do
    case Services.blocked?(a, b) do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, :blocked}
      {:error, :unavailable} -> {:error, :social_unavailable}
    end
  end

  ## Versions

  def versions(user_id, project_id) do
    with {:ok, project, _role} <- access(user_id, project_id, :view) do
      {:ok,
       Repo.all(
         from v in Version,
           where: v.project_id == ^project.id,
           order_by: [desc: v.number],
           select: %{v | snapshot: nil}
       )}
    end
  end

  @doc "Saves an immutable snapshot of the current content."
  def create_version(user_id, project_id, attrs) do
    Repo.transact(fn ->
      with {:ok, project, _role} <- access(user_id, project_id, :edit, lock: true),
           {:ok, note} <- note(attrs["note"]) do
        {:ok, insert_version(load(project), user_id, "manual", note)}
      end
    end)
  end

  @doc "Restores a version: its content becomes the current one and a new version (history kept)."
  def restore_version(user_id, project_id, version_id) do
    change_content(user_id, project_id, :edit, fn project, _role ->
      with {:ok, id} <- cast(version_id),
           %Version{} = version <- Repo.get_by(Version, id: id, project_id: project.id) do
        project = apply_snapshot(project, version.snapshot)
        note = "Restored from version #{version.number}"
        {:ok, insert_version(project, user_id, "restore", note)}
      else
        _ -> {:error, :not_found}
      end
    end)
  end

  @doc false
  def insert_version(%Project{} = project, user_id, source, note) do
    number =
      (Repo.one(from v in Version, where: v.project_id == ^project.id, select: max(v.number)) ||
         0) + 1

    Repo.insert!(%Version{
      project_id: project.id,
      number: number,
      note: note,
      source: source,
      author_id: user_id,
      snapshot: snapshot(project)
    })
  end

  @doc "Plain-data image of the content (brief, modules, lessons, images): versions, checks, import."
  def snapshot(%Project{} = p) do
    p =
      if Ecto.assoc_loaded?(p.modules) and Ecto.assoc_loaded?(p.images) and
           Ecto.assoc_loaded?(p.media),
         do: p,
         else: load(p)

    %{
      "brief" => Map.new(Project.brief_fields(), &{Atom.to_string(&1), Map.fetch!(p, &1)}),
      "modules" =>
        for m <- p.modules do
          %{
            "id" => m.id,
            "title" => m.title,
            "lessons" =>
              for l <- m.lessons do
                %{
                  "id" => l.id,
                  "title" => l.title,
                  "kind" => l.kind,
                  "body" => l.body,
                  "xp_reward" => l.xp_reward,
                  "content" => l.content
                }
              end
          }
        end,
      "images" =>
        for(i <- p.images, do: %{"id" => i.id, "alt" => i.alt, "lesson_id" => i.lesson_id}),
      "media" => Enum.map(p.media, &MlStudio.View.medium/1)
    }
  end

  # Replaces the brief and the modules/lessons by those of a snapshot (new lesson ids: image ↔
  # lesson links of the replaced lessons are cleared by their foreign key).
  defp apply_snapshot(project, snapshot) do
    project =
      project
      |> Project.brief_changeset(snapshot["brief"])
      |> Changeset.put_change(:lock_version, project.lock_version + 1)
      |> Repo.update!()

    Repo.delete_all(from m in CourseModule, where: m.project_id == ^project.id)

    for {m, i} <- Enum.with_index(snapshot["modules"], 1) do
      module = Repo.insert!(%CourseModule{project_id: project.id, position: i, title: m["title"]})

      for {l, j} <- Enum.with_index(m["lessons"], 1) do
        Repo.insert!(%Lesson{
          project_id: project.id,
          module_id: module.id,
          position: j,
          title: l["title"],
          kind: l["kind"],
          body: l["body"],
          xp_reward: l["xp_reward"],
          content: l["content"]
        })
      end
    end

    load(project)
  end

  defp note(nil), do: {:ok, ""}

  defp note(note) when is_binary(note) do
    note = String.trim(note)

    if String.length(note) <= 200,
      do: {:ok, note},
      else: {:error, {:invalid, %{note: ["should be at most 200 character(s)"]}}}
  end

  defp note(_note), do: {:error, {:invalid, %{note: ["is invalid"]}}}

  ## Content changes

  @doc false
  # Runs `fun.(project, role)` in a transaction holding the project row, then bumps the revision.
  def change_content(user_id, project_id, need, fun) do
    result =
      Repo.transact(fn ->
        with {:ok, project, role} <- access(user_id, project_id, need, lock: true),
             :ok <- editable(project),
             {:ok, value} <- fun.(project, role) do
          {:ok, {value, bump(project)}}
        end
      end)

    case result do
      {:ok, {value, project}} ->
        Events.project_changed(project, user_id)
        {:ok, value}

      error ->
        error
    end
  end

  @doc "`:ok` unless the project is locked by the review workflow."
  def editable(%Project{status: status}) when status in @locked, do: {:error, :locked}
  def editable(%Project{}), do: :ok

  defp bump(project) do
    status = if project.status == "published", do: "draft", else: project.status

    {1, [project]} =
      from(p in Project, where: p.id == ^project.id, select: p)
      |> Repo.update_all(
        inc: [content_revision: 1],
        set: [status: status, updated_at: DateTime.utc_now(:second)]
      )

    project
  end

  defp save_locked(changeset, current) do
    case changeset
         |> Changeset.optimistic_lock(:lock_version)
         |> Repo.update(stale_error_field: :lock_version) do
      {:ok, saved} ->
        {:ok, saved}

      {:error, changeset} ->
        if Keyword.has_key?(changeset.errors, :lock_version),
          do: {:error, {:conflict, current.()}},
          else: {:error, changeset}
    end
  end

  defp lock_version(%{"lock_version" => version}) when is_integer(version), do: {:ok, version}
  defp lock_version(_attrs), do: {:error, {:invalid, %{lock_version: ["can't be blank"]}}}

  defp child(schema, project, id) do
    with {:ok, id} <- cast(id),
         %{} = child <- Repo.get_by(schema, id: id, project_id: project.id) do
      {:ok, child}
    else
      _ -> {:error, :not_found}
    end
  end

  defp cast(id) when is_binary(id), do: Ecto.UUID.cast(id)
  defp cast(_id), do: :error

  defp next_position(siblings),
    do: (Repo.one(from s in siblings, select: max(s.position)) || 0) + 1

  defp below(query, max),
    do: if(Repo.aggregate(query, :count) < max, do: :ok, else: {:error, :too_many_collaborators})

  # Positions are unique per parent, checked at commit time (deferred constraint).
  defp reorder(siblings, ids, field) do
    current = Repo.all(from s in siblings, select: s.id)

    if is_list(ids) and length(ids) == length(current) and Enum.sort(ids) == Enum.sort(current) do
      set_positions(siblings, ids)
      :ok
    else
      {:error, {:invalid, %{field => ["must list every item once"]}}}
    end
  end

  defp renumber(siblings),
    do: set_positions(siblings, Repo.all(from s in siblings, order_by: s.position, select: s.id))

  defp set_positions(siblings, ids) do
    for {id, position} <- Enum.with_index(ids, 1) do
      from(s in siblings, where: s.id == ^id) |> Repo.update_all(set: [position: position])
    end
  end
end
