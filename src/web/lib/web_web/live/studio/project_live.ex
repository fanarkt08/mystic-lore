defmodule MysticWeb.Studio.ProjectLive do
  @moduledoc """
  Project editor in five steps, with autosave and conflict resolution between collaborators.
  """
  use MysticWeb, :live_view
  import MysticWeb.StudioComponents
  alias MysticWeb.Studio.Brief

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket =
      assign(socket,
        id: id,
        page_title: gettext("Studio"),
        saved: %{},
        conflict: nil,
        confirm: nil,
        announce: "",
        checks: nil,
        versions: nil,
        generations: []
      )

    case Api.get(socket, :studio, "/api/projects/:id", path_params: [id: id]) do
      {:ok, %{"project" => project}} ->
        socket =
          if connected?(socket) do
            MlShared.Events.subscribe("studio:project:#{id}")
            load_project(socket)
          else
            assign_project(socket, project)
          end

        {:ok,
         socket
         |> load_ai()
         |> load_generations()
         |> load_credits()
         |> allow_upload(:image,
           accept: ~w(.png .jpg .jpeg .webp),
           max_entries: 1,
           max_file_size: 2_097_152
         )
         |> allow_upload(:video,
           accept: ~w(.webm .mp4),
           max_entries: 1,
           max_file_size: 52_428_800
         )
         # `.vtt` has no MIME type known to Phoenix: any file, the studio validates the WebVTT itself
         |> allow_upload(:captions, accept: :any, max_entries: 1, max_file_size: 262_144)}

      {:error, {:http, 404, _}} ->
        raise MysticWeb.NotFoundError

      error ->
        {:ok, assign(socket, project: {:error, error_message(error)}, step: "brief")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    step = if params["step"] in steps(), do: params["step"], else: "brief"
    socket = assign(socket, step: step, lesson_id: params["lesson"])

    case socket.assigns.project do
      %{} -> {:noreply, socket |> select_lesson() |> load_step()}
      _ -> {:noreply, socket}
    end
  end

  ## Loading

  defp load_project(socket) do
    case Api.get(socket, :studio, "/api/projects/:id", path_params: [id: socket.assigns.id]) do
      {:ok, %{"project" => project}} -> socket |> assign_project(project) |> select_lesson()
      _ -> socket
    end
  end

  defp assign_project(socket, project) do
    assign(socket,
      project: project,
      page_title: project["title"],
      owner: project["role"] == "owner",
      editable:
        project["role"] in ["owner", "editor"] and
          project["status"] not in ["submitted", "approved"],
      brief_form: to_form(Brief.params(project), as: :brief)
    )
  end

  defp select_lesson(%{assigns: %{project: %{} = project}} = socket) do
    lessons = lessons(project)
    lesson = Enum.find(lessons, &(&1["id"] == socket.assigns[:lesson_id])) || List.first(lessons)

    assign(socket,
      lesson: lesson,
      lesson_form: lesson && to_form(lesson_params(lesson), as: :lesson)
    )
  end

  defp select_lesson(socket), do: socket

  defp load_step(%{assigns: %{step: step}} = socket) when step in ["review", "publish"] do
    socket = load_checks(socket)
    if step == "review", do: load_versions(socket), else: socket
  end

  defp load_step(socket), do: socket

  defp load_ai(socket) do
    case Api.get(socket, :studio, "/api/ai") do
      {:ok, %{"provider" => _} = ai} -> assign(socket, ai: ai)
      _ -> assign(socket, ai: :unavailable)
    end
  end

  defp load_generations(socket) do
    case Api.get(socket, :studio, "/api/projects/:id/generations",
           path_params: [id: socket.assigns.id]
         ) do
      {:ok, %{"generations" => list}} -> assign(socket, generations: list)
      _ -> socket
    end
  end

  defp load_credits(socket) do
    case Api.get(socket, :billing, "/api/me/credits") do
      {:ok, %{"balance" => _} = credits} -> assign(socket, credits: credits)
      _ -> assign(socket, credits: :unavailable)
    end
  end

  defp load_checks(socket) do
    case Api.get(socket, :studio, "/api/projects/:id/checks",
           path_params: [id: socket.assigns.id]
         ) do
      {:ok, %{"checks" => _} = checks} -> assign(socket, checks: checks)
      _ -> assign(socket, checks: :unavailable)
    end
  end

  defp load_versions(socket) do
    case Api.get(socket, :studio, "/api/projects/:id/versions",
           path_params: [id: socket.assigns.id]
         ) do
      {:ok, %{"versions" => list}} -> assign(socket, versions: list)
      _ -> assign(socket, versions: :unavailable)
    end
  end

  ## Real time

  @impl true
  def handle_info({:studio_generation, _project_id, %{"id" => id} = generation}, socket) do
    generations = [generation | Enum.reject(socket.assigns.generations, &(&1["id"] == id))]
    generations = Enum.sort_by(generations, & &1["inserted_at"], :desc)
    socket = assign(socket, generations: generations)

    if generation["status"] in ["succeeded", "failed", "cancelled"],
      do: {:noreply, load_credits(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:studio_project, _project_id, %{"by" => by}}, socket) do
    if by == socket.assigns.current_user["id"],
      do: {:noreply, socket},
      else: {:noreply, socket |> load_project() |> load_step()}
  end

  def handle_info({:credits_changed, _user_id, _balance}, socket),
    do: {:noreply, load_credits(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Brief (autosave)

  @impl true
  def handle_event("save_brief", %{"brief" => params}, socket) do
    payload = Brief.payload(params)

    socket
    |> assign(brief_form: to_form(params, as: :brief))
    |> save("brief", payload)
    |> noreply()
  end

  ## Conflicts: the author decides

  def handle_event(
        "keep_mine",
        _params,
        %{assigns: %{conflict: %{key: key, mine: mine, current: current}}} = socket
      ) do
    socket
    |> assign(conflict: nil)
    |> save(key, Map.put(mine, "lock_version", current["lock_version"]))
    |> noreply()
  end

  def handle_event("use_theirs", _params, socket),
    do: socket |> assign(conflict: nil) |> load_project() |> noreply()

  ## Modules and lessons

  def handle_event("add_module", %{"title" => title}, socket) do
    socket
    |> request(:post, "/modules", %{"title" => title}, gettext("Module added."))
    |> noreply()
  end

  def handle_event("save_module", %{"module_id" => id, "title" => title}, socket) do
    socket |> save("module:" <> id, %{"title" => title}) |> noreply()
  end

  def handle_event("delete_module", %{"id" => id}, socket) do
    socket |> request(:delete, "/modules/#{id}", nil, gettext("Module deleted.")) |> noreply()
  end

  def handle_event("move_module", %{"id" => id, "dir" => dir}, socket) do
    modules = socket.assigns.project["modules"]

    case move(Enum.map(modules, & &1["id"]), id, dir) do
      {:ok, ids, position} ->
        title = Enum.find(modules, &(&1["id"] == id))["title"]

        socket
        |> request(:put, "/modules/order", %{"module_ids" => ids}, nil)
        |> moved("module-#{id}", dir, position, length(ids), title)
        |> noreply()

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("add_lesson", %{"module_id" => module_id} = params, socket) do
    body = Map.take(params, ["title", "kind"])

    socket
    |> request(:post, "/modules/#{module_id}/lessons", body, gettext("Lesson added."))
    |> noreply()
  end

  def handle_event("move_lesson", %{"module_id" => module_id, "id" => id, "dir" => dir}, socket) do
    lessons = Enum.find(socket.assigns.project["modules"], &(&1["id"] == module_id))["lessons"]

    case move(Enum.map(lessons, & &1["id"]), id, dir) do
      {:ok, ids, position} ->
        title = Enum.find(lessons, &(&1["id"] == id))["title"]

        socket
        |> request(:put, "/modules/#{module_id}/lessons/order", %{"lesson_ids" => ids}, nil)
        |> moved("lesson-#{id}", dir, position, length(ids), title)
        |> noreply()

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_lesson", %{"id" => id}, socket) do
    socket |> request(:delete, "/lessons/#{id}", nil, gettext("Lesson deleted.")) |> noreply()
  end

  def handle_event("save_lesson", %{"lesson" => params}, socket) do
    lesson = socket.assigns.lesson

    content = lesson["content"] || %{}

    # switching the model or the game shows other fields: the form restarts from the saved lesson
    switched =
      Enum.any?(~w(model game), &(Map.has_key?(params, &1) and params[&1] != content[&1]))

    socket =
      socket
      |> assign(lesson_form: to_form(params, as: :lesson))
      |> save("lesson:" <> lesson["id"], lesson_payload(lesson["kind"], params, content))

    if switched, do: {:noreply, select_lesson(socket)}, else: {:noreply, socket}
  end

  def handle_event("choices", %{"change" => change}, %{assigns: %{lesson: lesson}} = socket) do
    choices = lesson["content"]["choices"] || []

    choices =
      case change do
        "add" when length(choices) < 6 -> choices ++ [""]
        "remove" when length(choices) > 2 -> Enum.drop(choices, -1)
        _ -> choices
      end

    socket
    |> save("lesson:" <> lesson["id"], %{"content" => %{"choices" => choices}})
    |> select_lesson()
    |> noreply()
  end

  ## AI

  def handle_event("prepare", %{"kind" => kind} = params, socket) do
    {:noreply,
     assign(socket,
       confirm: confirm(socket, kind, params["lesson_id"], nil, default_brief(socket, kind))
     )}
  end

  def handle_event("prepare_retry", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.generations, &(&1["id"] == id)) do
      nil ->
        {:noreply, socket}

      g ->
        {:noreply,
         assign(socket, confirm: confirm(socket, g["kind"], g["lesson_id"], g["id"], g["brief"]))}
    end
  end

  def handle_event("close_confirm", _params, socket), do: {:noreply, assign(socket, confirm: nil)}

  def handle_event("confirm_generation", params, %{assigns: %{confirm: %{} = c}} = socket) do
    result =
      if c.retry_of do
        Api.post(socket, :studio, "/api/generations/:id/retry",
          path_params: [id: c.retry_of],
          json: %{confirm_cost: c.cost}
        )
      else
        Api.post(socket, :studio, "/api/projects/:id/generations",
          path_params: [id: socket.assigns.id],
          json: %{
            kind: c.kind,
            lesson_id: c.lesson_id,
            brief: params["brief"],
            confirm_cost: c.cost
          }
        )
      end

    case result do
      {:ok, %{"generation" => generation}} ->
        {:noreply,
         socket
         |> assign(confirm: nil)
         |> upsert(generation)
         |> load_credits()
         |> put_flash(:info, gettext("Generation started: %{n} credits reserved.", n: c.cost))}

      {:error, {:http, 409, %{"error" => "cost_mismatch", "cost" => cost}}} = error ->
        {:noreply,
         assign(socket, confirm: Map.merge(c, %{cost: cost, error: error_message(error)}))}

      error ->
        {:noreply, socket |> assign(confirm: nil) |> put_flash(:error, error_message(error))}
    end
  end

  def handle_event("cancel_generation", %{"id" => id}, socket) do
    case Api.post(socket, :studio, "/api/generations/:id/cancel", path_params: [id: id]) do
      {:ok, %{"generation" => generation}} ->
        {:noreply,
         socket
         |> upsert(generation)
         |> put_flash(:info, gettext("Generation cancelled: its credits are refunded."))}

      error ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("apply_generation", %{"id" => id}, socket) do
    case Api.post(socket, :studio, "/api/generations/:id/apply", path_params: [id: id]) do
      {:ok, %{"generation" => generation}} ->
        {:noreply,
         socket
         |> upsert(generation)
         |> load_project()
         |> put_flash(
           :info,
           gettext("Added to the project. Review and rewrite it in your own words.")
         )}

      error ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("consent", %{"share" => share}, socket) do
    case Api.put(socket, :studio, "/api/me/ai-settings",
           json: %{share_drafts_with_ai: share == "true"}
         ) do
      {:ok, %{"share_drafts_with_ai" => value}} ->
        {:noreply, update(socket, :ai, &Map.put(&1, "share_drafts_with_ai", value))}

      error ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  ## Images

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("upload_image", %{"alt" => alt} = params, socket) do
    case consume_uploaded_entries(socket, :image, fn %{path: path}, _entry ->
           {:ok, File.read!(path)}
         end) do
      [bytes] ->
        body = %{
          "data" => Base.encode64(bytes),
          "alt" => alt,
          "lesson_id" => blank_to_nil(params["lesson_id"])
        }

        socket |> request(:post, "/images", body, gettext("Image added.")) |> noreply()

      [] ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Choose an image first (PNG, JPEG or WebP, 2 MB at most).")
         )}
    end
  end

  ## Video lessons: the video file and its WebVTT caption tracks

  def handle_event("upload_video", _params, %{assigns: %{lesson: %{"id" => lesson_id}}} = socket) do
    case consume_uploaded_entries(socket, :video, fn %{path: path}, _entry ->
           {:ok, File.read!(path)}
         end) do
      [bytes] ->
        Api.post(socket, :studio, "/api/projects/:id/lessons/:lesson_id/video",
          path_params: [id: socket.assigns.id, lesson_id: lesson_id],
          body: bytes,
          headers: [{"content-type", "application/octet-stream"}],
          receive_timeout: 60_000
        )
        |> media_result(socket, gettext("Video uploaded."))

      [] ->
        {:noreply,
         put_flash(socket, :error, gettext("Choose a video first (WebM or MP4, 50 MB at most)."))}
    end
  end

  def handle_event(
        "upload_captions",
        params,
        %{assigns: %{lesson: %{"id" => lesson_id}}} = socket
      ) do
    case consume_uploaded_entries(socket, :captions, fn %{path: path}, _entry ->
           {:ok, File.read!(path)}
         end) do
      [text] ->
        lang = params["lang"]

        label =
          if blank_to_nil(String.trim(params["label"] || "")),
            do: params["label"],
            else: language(lang)

        Api.post(socket, :studio, "/api/projects/:id/lessons/:lesson_id/captions",
          path_params: [id: socket.assigns.id, lesson_id: lesson_id],
          json: %{"lang" => lang, "label" => label, "vtt" => text}
        )
        |> media_result(socket, gettext("Captions added."))

      [] ->
        {:noreply, put_flash(socket, :error, gettext("Choose a WebVTT file (.vtt) first."))}
    end
  end

  def handle_event(
        "delete_captions",
        %{"lang" => lang},
        %{assigns: %{lesson: %{"id" => lesson_id}}} = socket
      ) do
    Api.delete(socket, :studio, "/api/projects/:id/lessons/:lesson_id/captions/:lang",
      path_params: [id: socket.assigns.id, lesson_id: lesson_id, lang: lang]
    )
    |> media_result(socket, gettext("Captions removed."))
  end

  def handle_event("save_image", %{"image_id" => id} = params, socket) do
    socket
    |> save("image:" <> id, %{
      "alt" => params["alt"],
      "lesson_id" => blank_to_nil(params["lesson_id"])
    })
    |> noreply()
  end

  def handle_event("delete_image", %{"id" => id}, socket) do
    socket |> request(:delete, "/images/#{id}", nil, gettext("Image deleted.")) |> noreply()
  end

  ## Collaborators

  def handle_event("invite", %{"username" => username, "role" => role}, socket) do
    socket
    |> request(
      :post,
      "/collaborators",
      %{"username" => username, "role" => role},
      gettext("Collaborator added.")
    )
    |> noreply()
  end

  def handle_event("set_role", %{"user_id" => user_id, "role" => role}, socket) do
    socket
    |> request(:patch, "/collaborators/#{user_id}", %{"role" => role}, gettext("Role updated."))
    |> noreply()
  end

  def handle_event("remove_collaborator", %{"user_id" => user_id}, socket) do
    if user_id == socket.assigns.current_user["id"] do
      case Api.delete(socket, :studio, "/api/projects/:id/collaborators/:user_id",
             path_params: [id: socket.assigns.id, user_id: user_id]
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("You left the project."))
           |> push_navigate(to: ~p"/studio")}

        error ->
          {:noreply, put_flash(socket, :error, error_message(error))}
      end
    else
      socket
      |> request(:delete, "/collaborators/#{user_id}", nil, gettext("Collaborator removed."))
      |> noreply()
    end
  end

  ## Versions

  def handle_event("save_version", %{"note" => note}, socket) do
    case Api.post(socket, :studio, "/api/projects/:id/versions",
           path_params: [id: socket.assigns.id],
           json: %{note: note}
         ) do
      {:ok, %{"version" => v}} ->
        {:noreply,
         socket
         |> load_versions()
         |> put_flash(:info, gettext("Version %{n} saved.", n: v["number"]))}

      error ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event("restore_version", %{"id" => version_id}, socket) do
    case Api.post(socket, :studio, "/api/projects/:id/versions/:version_id/restore",
           path_params: [id: socket.assigns.id, version_id: version_id]
         ) do
      {:ok, %{"version" => v, "project" => project}} ->
        {:noreply,
         socket
         |> assign_project(project)
         |> select_lesson()
         |> load_versions()
         |> load_checks()
         |> put_flash(
           :info,
           gettext("Restored: the content is now version %{n}.", n: v["number"])
         )}

      error ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  ## Publication

  def handle_event("attest", %{"attest" => values}, socket) do
    body = Map.new(~w(accuracy safety accessibility), &{&1, values[&1] == "true"})

    case Api.put(socket, :studio, "/api/projects/:id/attestations",
           path_params: [id: socket.assigns.id],
           json: body
         ) do
      {:ok, %{"attestations" => attestations}} ->
        {:noreply,
         socket |> update(:project, &Map.put(&1, "attestations", attestations)) |> load_checks()}

      error ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  def handle_event(action, _params, socket) when action in ["submit", "withdraw"] do
    case Api.post(socket, :studio, "/api/projects/:id/#{action}",
           path_params: [id: socket.assigns.id]
         ) do
      {:ok, %{"project" => _}} ->
        message =
          if action == "submit",
            do:
              gettext("Submitted: a moderator will review it. The project is locked meanwhile."),
            else: gettext("Withdrawn from review: you can edit it again.")

        {:noreply, socket |> load_project() |> load_checks() |> put_flash(:info, message)}

      {:error, {:http, 422, %{"error" => "checks_failed", "checks" => checks}}} = error ->
        {:noreply,
         socket
         |> assign(checks: %{"checks" => checks, "ready" => false})
         |> put_flash(:error, error_message(error))}

      error ->
        {:noreply, put_flash(socket, :error, error_message(error))}
    end
  end

  ## Helpers

  defp noreply(socket), do: {:noreply, socket}

  # Autosave of one item, keyed "brief" | "module:<id>" | "lesson:<id>" | "image:<id>".
  defp save(socket, key, payload) do
    {path, version} =
      case String.split(key, ":", parts: 2) do
        ["brief"] -> {"", socket.assigns.project["lock_version"]}
        ["module", id] -> {"/modules/#{id}", find_module(socket, id)["lock_version"]}
        ["lesson", id] -> {"/lessons/#{id}", find_lesson(socket, id)["lock_version"]}
        ["image", id] -> {"/images/#{id}", nil}
      end

    payload = if version, do: Map.put_new(payload, "lock_version", version), else: payload

    case Api.patch(socket, :studio, "/api/projects/:id" <> path,
           path_params: [id: socket.assigns.id],
           json: payload
         ) do
      {:ok, body} ->
        socket |> apply_saved(key, body) |> put_saved(key, {:ok, saved_at(body)})

      {:error, {:http, 409, %{"error" => "conflict", "current" => current}}} ->
        assign(socket, conflict: %{key: key, mine: payload, current: current})

      error ->
        put_saved(socket, key, {:error, error_message(error)})
    end
  end

  defp saved_at(body),
    do:
      body |> Map.values() |> hd() |> Map.get("updated_at") ||
        DateTime.utc_now() |> DateTime.to_iso8601()

  defp apply_saved(socket, "brief", %{"project" => brief}),
    do: update(socket, :project, &Map.merge(&1, brief))

  defp apply_saved(socket, "module:" <> id, %{"module" => module}),
    do:
      update_project(socket, fn p ->
        update_in(p["modules"], &replace(&1, id, Map.drop(module, ["lessons"]), :merge))
      end)

  defp apply_saved(socket, "lesson:" <> id, %{"lesson" => lesson}) do
    socket
    |> update_project(fn p ->
      update_in(
        p["modules"],
        &Enum.map(&1, fn m ->
          Map.update!(m, "lessons", fn ls -> replace(ls, id, lesson, :replace) end)
        end)
      )
    end)
    |> assign(lesson: lesson)
  end

  defp apply_saved(socket, "image:" <> id, %{"image" => image}),
    do:
      update_project(socket, fn p -> update_in(p["images"], &replace(&1, id, image, :replace)) end)

  defp update_project(socket, fun), do: assign(socket, project: fun.(socket.assigns.project))

  defp replace(items, id, new, mode),
    do:
      Enum.map(
        items,
        &if(&1["id"] == id, do: if(mode == :merge, do: Map.merge(&1, new), else: new), else: &1)
      )

  defp put_saved(socket, key, state), do: update(socket, :saved, &Map.put(&1, key, state))

  # A content request on the project, followed by a reload of the project.
  defp request(socket, method, path, body, success) do
    opts = [path_params: [id: socket.assigns.id]] ++ if(body, do: [json: body], else: [])

    case apply(Api, method, [socket, :studio, "/api/projects/:id" <> path, opts]) do
      {:ok, _} ->
        socket = load_project(socket)
        if success, do: put_flash(socket, :info, success), else: socket

      error ->
        put_flash(socket, :error, error_message(error))
    end
  end

  defp move(ids, id, dir) do
    index = Enum.find_index(ids, &(&1 == id))
    target = if dir == "up", do: index && index - 1, else: index && index + 1

    if index && target in 0..(length(ids) - 1)//1 do
      {:ok, ids |> List.delete_at(index) |> List.insert_at(target, id), target + 1}
    else
      :error
    end
  end

  # Keeps the keyboard focus on the moved item and announces its new place.
  defp moved(socket, dom_id, dir, position, count, title) do
    # at the top (bottom) the same button is disabled: the other one gets the focus
    button =
      cond do
        dir == "up" and position == 1 -> "down"
        dir == "down" and position == count -> "up"
        true -> dir
      end

    socket
    |> assign(
      announce:
        gettext("“%{title}” moved to position %{position} of %{count}.",
          title: title,
          position: position,
          count: count
        )
    )
    |> push_event("studio:focus", %{id: "#{dom_id}-#{button}"})
  end

  defp upsert(socket, generation),
    do:
      assign(socket,
        generations: [
          generation | Enum.reject(socket.assigns.generations, &(&1["id"] == generation["id"]))
        ]
      )

  defp confirm(socket, kind, lesson_id, retry_of, brief) do
    costs = (is_map(socket.assigns.ai) && socket.assigns.ai["costs"]) || %{}
    %{kind: kind, lesson_id: lesson_id, retry_of: retry_of, brief: brief || "", cost: costs[kind]}
  end

  # With the demo provider the brief can start from the project; with an external one the author writes it.
  defp default_brief(%{assigns: %{ai: %{"external" => false}, project: p} = assigns}, kind) do
    case kind do
      "outline" -> Enum.join([p["title"] | p["objectives"] || []], ". ")
      _ -> (assigns[:lesson] || %{})["title"] || p["title"]
    end
  end

  defp default_brief(_socket, _kind), do: ""

  defp lessons(project), do: Enum.flat_map(project["modules"] || [], & &1["lessons"])

  defp find_module(socket, id),
    do: Enum.find(socket.assigns.project["modules"], &(&1["id"] == id)) || %{}

  defp find_lesson(socket, id),
    do: Enum.find(lessons(socket.assigns.project), &(&1["id"] == id)) || %{}

  defp lesson_params(lesson) do
    c = lesson["content"] || %{}

    %{
      "title" => lesson["title"],
      "xp_reward" => to_string(lesson["xp_reward"]),
      "body" => lesson["body"],
      "question" => c["question"],
      "explanation" => c["explanation"],
      "answer" => to_string(c["answer"]),
      "plants" => to_string(c["plants"]),
      "starter" => c["starter"],
      "hints" => Enum.join(c["hints"] || [], "\n"),
      # video
      "transcript" => c["transcript"],
      "duration_s" => to_string(c["duration_s"]),
      # simulation
      "model" => c["model"],
      "goal_text" => c["goal_text"],
      "steps" => to_string(c["steps"]),
      "distance" => to_string(c["distance"]),
      "dt" => to_string(c["dt"]),
      "max_eccentricity" => to_string(c["max_eccentricity"]),
      "min_revolutions" => to_string(c["min_revolutions"]),
      "species" => species_lines(c["species"]),
      "max_coefficient" => to_string(c["max_coefficient"]),
      "yield_pct" => to_string(c["yield_pct"]),
      "lowest_terms" => to_string(c["lowest_terms"] != false),
      # mini-game
      "game" => c["game"],
      "prompt" => c["prompt"],
      "items" => Enum.join(c["items"] || [], "\n"),
      "stars" => Enum.map_join(c["stars"] || [], "\n", &"#{&1["name"]}, #{&1["x"]}, #{&1["y"]}"),
      "path" => Enum.join(c["path"] || [], "\n")
    }
    |> Map.merge(range_params("velocity", c["velocity"]))
    |> Map.merge(range_params("star_mass", c["star_mass"]))
  end

  defp lesson_payload(kind, params, current) do
    content =
      case kind do
        "video" ->
          %{
            "transcript" => params["transcript"],
            "duration_s" => Brief.integer(params["duration_s"])
          }

        "simulation" ->
          model = params["model"]

          base = %{
            "model" => model,
            "goal_text" => params["goal_text"],
            # a new model starts from its own number of steps
            "steps" =>
              if(model == current["model"],
                do: Brief.integer(params["steps"]),
                else: if(model == "reaction", do: 6, else: 1000)
              )
          }

          if model == "reaction",
            do:
              Map.merge(base, %{
                "species" => species_payload(params["species"]),
                "max_coefficient" => Brief.integer(params["max_coefficient"]),
                "yield_pct" => Brief.integer(params["yield_pct"]),
                "lowest_terms" => params["lowest_terms"] == "true"
              }),
            else:
              Map.merge(base, %{
                "velocity" => range_payload(params, "velocity"),
                "star_mass" => range_payload(params, "star_mass"),
                "distance" => number(params["distance"]),
                "dt" => number(params["dt"]),
                "max_eccentricity" => number(params["max_eccentricity"]),
                "min_revolutions" => Brief.integer(params["min_revolutions"])
              })

        "minigame" ->
          base = %{"game" => params["game"], "prompt" => params["prompt"]}

          if params["game"] == "constellation",
            do:
              Map.merge(base, %{
                "stars" => stars_payload(params["stars"]),
                "path" => Brief.lines(params["path"]) || []
              }),
            else: Map.put(base, "items", Brief.lines(params["items"]) || [])

        "exercise" ->
          %{
            "question" => params["question"],
            "choices" => List.wrap(params["choices"]),
            "answer" => Brief.integer(params["answer"]),
            "explanation" => params["explanation"]
          }

        "coding" ->
          %{
            "plants" => Brief.integer(params["plants"]),
            "starter" => params["starter"],
            "hints" => Brief.lines(params["hints"])
          }
          |> Map.reject(fn {_k, v} -> is_nil(v) end)

        _ ->
          nil
      end

    %{
      "title" => params["title"],
      "body" => params["body"],
      "xp_reward" => Brief.integer(params["xp_reward"])
    }
    |> Map.merge(if(content, do: %{"content" => content}, else: %{}))
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp media_result({:ok, _}, socket, message),
    do: {:noreply, socket |> load_project() |> put_flash(:info, message)}

  defp media_result({:error, {:http, 422, %{"errors" => errors}}}, socket, _message) do
    details = errors |> Map.values() |> List.flatten() |> Enum.join(" ")
    {:noreply, put_flash(socket, :error, gettext("Refused: %{details}", details: details))}
  end

  defp media_result(error, socket, _message),
    do: {:noreply, put_flash(socket, :error, error_message(error))}

  @languages [
    {"en", "English"},
    {"fr", "Français"},
    {"es", "Español"},
    {"de", "Deutsch"},
    {"it", "Italiano"},
    {"pt", "Português"}
  ]

  defp language(lang), do: List.keyfind(@languages, lang, 0, {lang, lang}) |> elem(1)

  # a number typed in a form (`""` → nil, `"4"` → 4, `"0.1"` → 0.1)
  defp number(value) when is_binary(value) do
    value = String.trim(value)

    case Float.parse(value) do
      {n, ""} -> if String.contains?(value, [".", "e", "E"]), do: n, else: trunc(n)
      _ -> nil
    end
  end

  defp number(_value), do: nil

  defp range_params(prefix, range),
    do: Map.new(~w(min max step default), &{"#{prefix}_#{&1}", to_string((range || %{})[&1])})

  defp range_payload(params, prefix),
    do: Map.new(~w(min max step default), &{&1, number(params["#{prefix}_#{&1}"])})

  defp species_lines(species),
    do:
      Enum.map_join(
        species || [],
        "\n",
        &"#{&1["formula"]}, #{side_label(&1["side"])}, #{&1["initial"]}"
      )

  defp side_label("product"), do: gettext("product")
  defp side_label(_), do: gettext("reactant")

  # "H2, reactant, 10" per line; the French words of the interface are accepted too
  defp species_payload(text) do
    for line <- Brief.lines(text) || [] do
      case String.split(line, ",") |> Enum.map(&String.trim/1) do
        [formula, side, initial | _] ->
          %{"formula" => formula, "side" => side_key(side), "initial" => number(initial)}

        [formula, side] ->
          %{"formula" => formula, "side" => side_key(side), "initial" => 0}

        [formula] ->
          %{"formula" => formula, "side" => "reactant", "initial" => 0}
      end
    end
  end

  defp side_key(side) do
    case String.downcase(side) do
      s when s in ~w(product produit) -> "product"
      s when s in ~w(reactant réactif reactif) -> "reactant"
      s -> s
    end
  end

  # "Alkaid, 8, 62" per line
  defp stars_payload(text) do
    for line <- Brief.lines(text) || [] do
      case String.split(line, ",") |> Enum.map(&String.trim/1) do
        [name, x, y | _] -> %{"name" => name, "x" => Brief.integer(x), "y" => Brief.integer(y)}
        [name | _] -> %{"name" => name, "x" => nil, "y" => nil}
      end
    end
  end

  defp images_for(project, lesson_id),
    do: Enum.filter(project["images"] || [], &(&1["lesson_id"] == lesson_id))

  defp balance(%{"balance" => balance}), do: balance
  defp balance(_credits), do: nil

  ## Rendering

  @impl true
  def render(%{project: {:error, message}} = assigns) do
    assigns = assign(assigns, message: message)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:studio}
    >
      <.notice id="project-unavailable" kind="warning" title={gettext("Temporarily unavailable")}>
        {@message}
        <:actions>
          <.button navigate={~p"/studio"} variant="secondary">{gettext("Back to the studio")}</.button>
        </:actions>
      </.notice>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      active={:studio}
    >
      <div class="space-y-6" id="studio-project" phx-hook=".Focus">
        <.link navigate={~p"/studio"} class="link text-sm">← {gettext("Studio")}</.link>
        <header class="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
          <div class="min-w-0 space-y-2">
            <div class="flex flex-wrap items-center gap-2">
              <.status_tag status={@project["status"]} id="project-status" />
              <.tag>{role_label(@project["role"])}</.tag>
            </div>
            <h1 class="text-4xl md:text-5xl" id="project-title">{@project["title"]}</h1>
          </div>
          <p :if={is_map(@credits)} class="text-sm text-muted" id="credit-balance">
            <.icon name="hero-bolt" class="size-4" />
            {ngettext(
              "%{count} AI credit left this month",
              "%{count} AI credits left this month",
              @credits["balance"]
            )}
          </p>
        </header>

        <.step_nav project_id={@id} step={@step} />

        <.notice
          :if={@project["status"] in ["submitted", "approved"]}
          id="locked-notice"
          kind="info"
          title={gettext("Locked during the review")}
        >
          {gettext(
            "The project can't be edited while it is in review. It opens again if it is rejected or withdrawn."
          )}
        </.notice>
        <.notice :if={@project["role"] == "viewer"} id="viewer-notice" kind="info">
          {gettext("You can read this project; only its owner and editors can change it.")}
        </.notice>

        <.notice
          :if={@conflict}
          id="conflict"
          kind="warning"
          role="alert"
          title={gettext("A collaborator saved this first")}
        >
          {gettext(
            "Your last change wasn't saved because someone else changed the same item. Choose which version to keep."
          )}
          <:actions>
            <.button phx-click="keep_mine" id="keep-mine">{gettext("Keep my version")}</.button>
            <.button phx-click="use_theirs" variant="secondary" id="use-theirs">{gettext(
              "Use the latest version"
            )}</.button>
          </:actions>
        </.notice>

        <p class="sr-only" aria-live="polite" id="studio-announce">{@announce}</p>

        <div class={[
          "grid gap-8",
          @step in ["outline", "build"] && "lg:grid-cols-[minmax(0,1fr)_20rem]"
        ]}>
          <div class="min-w-0 space-y-6">
            {step(assigns)}
          </div>
          <aside
            :if={@step in ["outline", "build"]}
            class="space-y-4"
            aria-label={gettext("AI assistant")}
          >
            {ai_panel(assigns)}
          </aside>
        </div>

        <.confirm_dialog :if={@confirm} confirm={@confirm} ai={@ai} credits={@credits} />
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Focus">
        export default {
          mounted() {
            this.handleEvent("studio:focus", ({id}) => {
              const el = document.getElementById(id)
              if (el) el.focus()
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  defp step(%{step: "brief"} = assigns) do
    ~H"""
    <section class="card space-y-5" aria-labelledby="brief-title">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h2 id="brief-title" class="text-3xl">{gettext("Brief")}</h2>
        <.saved_status id="brief-saved" state={@saved["brief"]} />
      </div>
      <.form for={@brief_form} id="brief-form" phx-change="save_brief" phx-submit="save_brief">
        <MysticWeb.Studio.Brief.brief_fields form={@brief_form} disabled={!@editable} />
      </.form>
    </section>
    <.collaborators project={@project} owner={@owner} current_user={@current_user} />
    """
  end

  defp step(%{step: "outline"} = assigns) do
    ~H"""
    <section class="space-y-4" aria-labelledby="outline-title">
      <h2 id="outline-title" class="text-3xl">{gettext("Outline")}</h2>
      <p class="text-muted">
        {gettext(
          "Modules become the chapters of the adventure. Reorder them with the arrow buttons (keyboard friendly)."
        )}
      </p>
      <ol class="space-y-4" id="modules">
        <li
          :for={{module, i} <- Enum.with_index(@project["modules"], 1)}
          id={"module-#{module["id"]}"}
          class="card space-y-3"
        >
          <div class="flex flex-wrap items-center gap-2">
            <span class="eyebrow">{gettext("Module %{n}", n: i)}</span>
            <div :if={@editable} class="ml-auto flex gap-1">
              <.button
                variant="ghost"
                phx-click="move_module"
                phx-value-id={module["id"]}
                phx-value-dir="up"
                id={"module-#{module["id"]}-up"}
                disabled={i == 1}
                aria-label={gettext("Move module “%{title}” up", title: module["title"])}
              >
                <.icon name="hero-arrow-up" />
              </.button>
              <.button
                variant="ghost"
                phx-click="move_module"
                phx-value-id={module["id"]}
                phx-value-dir="down"
                id={"module-#{module["id"]}-down"}
                disabled={i == length(@project["modules"])}
                aria-label={gettext("Move module “%{title}” down", title: module["title"])}
              >
                <.icon name="hero-arrow-down" />
              </.button>
              <.button
                variant="ghost"
                phx-click="delete_module"
                phx-value-id={module["id"]}
                data-confirm={gettext("Delete this module and its lessons?")}
                aria-label={gettext("Delete module “%{title}”", title: module["title"])}
              >
                <.icon name="hero-trash" />
              </.button>
            </div>
          </div>
          <.form
            for={%{}}
            id={"module-form-#{module["id"]}"}
            phx-change="save_module"
            phx-submit="save_module"
          >
            <input type="hidden" name="module_id" value={module["id"]} />
            <.input
              id={"module-title-#{module["id"]}"}
              name="title"
              value={module["title"]}
              label={gettext("Module title")}
              phx-debounce="800"
              disabled={!@editable}
            />
            <.saved_status
              id={"module-saved-#{module["id"]}"}
              state={@saved["module:" <> module["id"]]}
            />
          </.form>
          <ol class="space-y-2">
            <li
              :for={{lesson, j} <- Enum.with_index(module["lessons"], 1)}
              id={"lesson-row-#{lesson["id"]}"}
              class="studio-lesson-row"
            >
              <.icon name={kind_icon(lesson["kind"])} class="size-4 text-muted" />
              <.link
                patch={~p"/studio/#{@id}?step=build&lesson=#{lesson["id"]}"}
                class="link min-w-0 flex-1 truncate"
              >{lesson["title"]}</.link>
              <span class="text-xs text-muted">{kind_label(lesson["kind"])}</span>
              <span :if={@editable} class="flex gap-1">
                <.button
                  variant="ghost"
                  phx-click="move_lesson"
                  phx-value-module_id={module["id"]}
                  phx-value-id={lesson["id"]}
                  phx-value-dir="up"
                  id={"lesson-#{lesson["id"]}-up"}
                  disabled={j == 1}
                  aria-label={gettext("Move lesson “%{title}” up", title: lesson["title"])}
                >
                  <.icon name="hero-arrow-up" class="size-4" />
                </.button>
                <.button
                  variant="ghost"
                  phx-click="move_lesson"
                  phx-value-module_id={module["id"]}
                  phx-value-id={lesson["id"]}
                  phx-value-dir="down"
                  id={"lesson-#{lesson["id"]}-down"}
                  disabled={j == length(module["lessons"])}
                  aria-label={gettext("Move lesson “%{title}” down", title: lesson["title"])}
                >
                  <.icon name="hero-arrow-down" class="size-4" />
                </.button>
                <.button
                  variant="ghost"
                  phx-click="delete_lesson"
                  phx-value-id={lesson["id"]}
                  data-confirm={gettext("Delete this lesson?")}
                  aria-label={gettext("Delete lesson “%{title}”", title: lesson["title"])}
                >
                  <.icon name="hero-trash" class="size-4" />
                </.button>
              </span>
            </li>
          </ol>
          <.form
            :if={@editable}
            for={%{}}
            id={"add-lesson-#{module["id"]}"}
            phx-submit="add_lesson"
            class="studio-inline-form"
          >
            <input type="hidden" name="module_id" value={module["id"]} />
            <.input
              id={"new-lesson-title-#{module["id"]}"}
              name="title"
              value=""
              label={gettext("New lesson")}
              maxlength="200"
              required
            />
            <.input
              id={"new-lesson-kind-#{module["id"]}"}
              name="kind"
              value="story"
              type="select"
              label={gettext("Format")}
              options={[
                {gettext("Story"), "story"},
                {gettext("Quiz"), "exercise"},
                {gettext("Coding (GroveScript)"), "coding"},
                {gettext("Video (captions and transcript)"), "video"},
                {gettext("Simulation (orbit or reaction)"), "simulation"},
                {gettext("Mini-game (sequence or constellation)"), "minigame"}
              ]}
            />
            <.button type="submit" variant="secondary">{gettext("Add lesson")}</.button>
          </.form>
        </li>
      </ol>
      <p :if={@project["modules"] == []} class="text-muted" id="no-modules">
        {gettext("No module yet: add one, or ask the AI for an outline.")}
      </p>
      <.form
        :if={@editable}
        for={%{}}
        id="add-module"
        phx-submit="add_module"
        class="card studio-inline-form"
      >
        <.input
          id="new-module-title"
          name="title"
          value=""
          label={gettext("New module")}
          maxlength="200"
          required
        />
        <.button type="submit">{gettext("Add module")}</.button>
      </.form>
    </section>
    """
  end

  defp step(%{step: "build"} = assigns) do
    ~H"""
    <section class="space-y-4" aria-labelledby="build-title">
      <h2 id="build-title" class="text-3xl">{gettext("Build")}</h2>
      <nav :if={@lesson} aria-label={gettext("Lessons")} class="studio-lesson-tabs">
        <.link
          :for={l <- Enum.flat_map(@project["modules"], & &1["lessons"])}
          patch={~p"/studio/#{@id}?step=build&lesson=#{l["id"]}"}
          class="studio-lesson-tab"
          aria-current={l["id"] == @lesson["id"] && "page"}
        >
          {l["title"]}
        </.link>
      </nav>
      <p :if={!@lesson} class="text-muted" id="no-lesson">
        {gettext("Add lessons in the Outline step first.")}
      </p>
      <section :if={@lesson} class="card space-y-4" id={"editor-#{@lesson["id"]}"}>
        <div class="flex flex-wrap items-center justify-between gap-2">
          <p class="eyebrow">{kind_label(@lesson["kind"])}</p>
          <.saved_status id="lesson-saved" state={@saved["lesson:" <> @lesson["id"]]} />
        </div>
        <.form
          for={@lesson_form}
          id="lesson-form"
          phx-change="save_lesson"
          phx-submit="save_lesson"
          class="space-y-4"
        >
          <fieldset class="space-y-4" disabled={!@editable}>
            <.input
              field={@lesson_form[:title]}
              label={gettext("Lesson title")}
              maxlength="200"
              phx-debounce="800"
            />
            <.input
              field={@lesson_form[:body]}
              type="textarea"
              rows="6"
              label={gettext("Lesson text")}
              hint={gettext("Separate paragraphs with an empty line.")}
              phx-debounce="800"
            />
            <.input
              field={@lesson_form[:xp_reward]}
              type="number"
              label={gettext("XP reward")}
              phx-debounce="800"
            />
            <%= case @lesson["kind"] do %>
              <% "exercise" -> %>
                <.input
                  field={@lesson_form[:question]}
                  label={gettext("Question")}
                  maxlength="1000"
                  phx-debounce="800"
                />
                <fieldset class="space-y-2">
                  <legend class="label">{gettext("Choices (select the correct one)")}</legend>
                  <div
                    :for={{choice, i} <- Enum.with_index(@lesson["content"]["choices"] || [])}
                    class="studio-choice"
                  >
                    <input
                      type="radio"
                      name="lesson[answer]"
                      value={i}
                      id={"answer-#{i}"}
                      checked={@lesson["content"]["answer"] == i}
                      aria-label={gettext("Choice %{n} is correct", n: i + 1)}
                    />
                    <label for={"choice-#{i}"} class="sr-only">{gettext("Choice %{n}", n: i + 1)}</label>
                    <input
                      type="text"
                      name="lesson[choices][]"
                      id={"choice-#{i}"}
                      value={choice}
                      class="input"
                      maxlength="500"
                      phx-debounce="800"
                    />
                  </div>
                  <div class="flex gap-2">
                    <.button
                      type="button"
                      variant="ghost"
                      phx-click="choices"
                      phx-value-change="add"
                      id="add-choice"
                    >{gettext("Add a choice")}</.button>
                    <.button
                      type="button"
                      variant="ghost"
                      phx-click="choices"
                      phx-value-change="remove"
                      id="remove-choice"
                    >{gettext("Remove the last choice")}</.button>
                  </div>
                </fieldset>
                <.input
                  field={@lesson_form[:explanation]}
                  type="textarea"
                  rows="3"
                  label={gettext("Explanation of the correct answer")}
                  phx-debounce="800"
                />
              <% "coding" -> %>
                <p class="text-sm text-muted">
                  {gettext(
                    "GroveScript puzzle: the learner waters plants 0 to N−1, each exactly once, with a loop."
                  )}
                </p>
                <.input
                  field={@lesson_form[:plants]}
                  type="number"
                  label={gettext("Number of plants (2 to 10)")}
                  phx-debounce="800"
                />
                <.input
                  field={@lesson_form[:starter]}
                  type="textarea"
                  rows="4"
                  class="input code-editor"
                  spellcheck="false"
                  label={gettext("Starter spell")}
                  phx-debounce="800"
                />
                <.input
                  field={@lesson_form[:hints]}
                  type="textarea"
                  rows="3"
                  label={gettext("Hints")}
                  hint={gettext("One per line (1 to 5).")}
                  phx-debounce="800"
                />
              <% "video" -> %>
                <.input
                  field={@lesson_form[:transcript]}
                  type="textarea"
                  rows="8"
                  label={gettext("Full transcript (required)")}
                  hint={
                    gettext(
                      "Everything that is said, plus a short description of what is shown. Learners can read it instead of watching."
                    )
                  }
                  phx-debounce="800"
                />
                <.input
                  field={@lesson_form[:duration_s]}
                  type="number"
                  min="1"
                  max="7200"
                  label={gettext("Duration of the video (seconds)")}
                  phx-debounce="800"
                />
              <% "simulation" -> %>
                <.sim_editor form={@lesson_form} />
              <% "minigame" -> %>
                <.game_editor form={@lesson_form} />
              <% _ -> %>
            <% end %>
          </fieldset>
        </.form>
        <.video_media
          :if={@lesson["kind"] == "video"}
          lesson={@lesson}
          project={@project}
          id={@id}
          editable={@editable}
          uploads={@uploads}
        />
      </section>
      <.images project={@project} id={@id} editable={@editable} uploads={@uploads} saved={@saved} />
    </section>
    """
  end

  defp step(%{step: "review"} = assigns) do
    ~H"""
    <section class="card space-y-4" aria-labelledby="checks-title">
      <h2 id="checks-title" class="text-3xl">{gettext("Automatic checks")}</h2>
      <%= case @checks do %>
        <% %{"checks" => checks} -> %>
          <.check_list checks={checks} />
        <% :unavailable -> %>
          <.unavailable>{gettext("The checks can't be run right now.")}</.unavailable>
        <% _ -> %>
      <% end %>
    </section>
    <.attestations project={@project} owner={@owner} editable={@editable} />
    <section class="card space-y-4" aria-labelledby="preview-title" id="learner-preview">
      <h2 id="preview-title" class="text-3xl">{gettext("Learner preview")}</h2>
      <p class="text-sm text-muted">
        {gettext("Read-only: this is what learners will see (quiz answers are hidden).")}
      </p>
      <div :for={{module, i} <- Enum.with_index(@project["modules"], 1)} class="space-y-4">
        <h3 class="text-2xl">{gettext("Chapter %{n}: %{title}", n: i, title: module["title"])}</h3>
        <.lesson_preview
          :for={lesson <- module["lessons"]}
          lesson={lesson}
          project_id={@id}
          images={images_for(@project, lesson["id"])}
        />
      </div>
    </section>
    <.versions versions={@versions} editable={@editable} />
    """
  end

  defp step(%{step: "publish"} = assigns) do
    assigns =
      assign(assigns,
        ready:
          match?(%{"ready" => true}, assigns.checks) and
            get_in(assigns.project, ["attestations", "valid"]) == true
      )

    ~H"""
    <section class="card space-y-5" aria-labelledby="publish-title" id="publish">
      <h2 id="publish-title" class="text-3xl">{gettext("Publish")}</h2>
      <ol class="studio-timeline" aria-label={gettext("Publication status")}>
        <li
          :for={status <- ~w(draft submitted approved published)}
          aria-current={@project["status"] == status && "step"}
        >
          {status_label(status)}
        </li>
      </ol>
      <.notice
        :if={get_in(@project, ["review", "decision"]) == "rejected" and @project["status"] == "draft"}
        id="rejection"
        kind="warning"
        title={gettext("Changes requested by the moderators")}
      >
        {@project["review"]["reason"]}
      </.notice>
      <.notice
        :if={@project["status"] == "approved"}
        id="import-status"
        kind="info"
        title={gettext("Approved: publishing to the catalog")}
      >
        {get_in(@project, ["publication", "message"]) ||
          gettext("The import into the learning catalog is in progress.")}
      </.notice>
      <.notice
        :if={get_in(@project, ["publication", "slug"])}
        id="published"
        kind="success"
        title={gettext("Live in the academy")}
      >
        <.link href={~p"/adventures/#{@project["publication"]["slug"]}"} class="link">{gettext(
          "Open the published adventure"
        )}</.link>
      </.notice>
      <%= if @project["status"] == "draft" do %>
        <p :if={!@ready} class="text-muted" id="submit-blockers">
          {gettext(
            "To submit: every automatic check passes and you confirmed the three declarations for the current content (Review step)."
          )}
        </p>
        <.button
          :if={@owner}
          phx-click="submit"
          id="submit-project"
          disabled={!@ready}
          phx-disable-with={gettext("Submitting…")}
        >
          {gettext("Submit for review")}
        </.button>
      <% end %>
      <.button
        :if={@owner and @project["status"] == "submitted"}
        phx-click="withdraw"
        variant="secondary"
        id="withdraw-project"
      >
        {gettext("Withdraw from review")}
      </.button>
    </section>
    """
  end

  attr :project, :map, required: true
  attr :owner, :boolean, required: true
  attr :current_user, :map, required: true

  defp collaborators(assigns) do
    ~H"""
    <section class="card space-y-4" aria-labelledby="collaborators-title" id="collaborators">
      <h2 id="collaborators-title" class="text-2xl">{gettext("Collaborators")}</h2>
      <ul class="space-y-2">
        <li
          :for={c <- @project["collaborators"]}
          id={"collaborator-#{c["user_id"]}"}
          class="flex flex-wrap items-center gap-2"
        >
          <span class="font-medium text-ink">@{c["username"]}</span>
          <form :if={@owner} phx-change="set_role" id={"role-form-#{c["user_id"]}"}>
            <input type="hidden" name="user_id" value={c["user_id"]} />
            <label for={"role-#{c["user_id"]}"} class="sr-only">{gettext("Role of %{name}",
              name: c["username"]
            )}</label>
            <select id={"role-#{c["user_id"]}"} name="role" class="input">
              {Phoenix.HTML.Form.options_for_select(
                [{gettext("Editor"), "editor"}, {gettext("Viewer"), "viewer"}],
                c["role"]
              )}
            </select>
          </form>
          <.tag :if={!@owner}>{role_label(c["role"])}</.tag>
          <.button
            :if={@owner or c["user_id"] == @current_user["id"]}
            variant="ghost"
            phx-click="remove_collaborator"
            phx-value-user_id={c["user_id"]}
            data-confirm={gettext("Remove this collaborator?")}
          >
            {if c["user_id"] == @current_user["id"],
              do: gettext("Leave the project"),
              else: gettext("Remove")}
          </.button>
        </li>
      </ul>
      <p :if={@project["collaborators"] == []} class="text-sm text-muted">
        {gettext("Nobody else yet.")}
      </p>
      <.form :if={@owner} for={%{}} id="invite-form" phx-submit="invite" class="studio-inline-form">
        <.input id="invite-username" name="username" value="" label={gettext("Username")} required />
        <.input
          id="invite-role"
          name="role"
          value="editor"
          type="select"
          label={gettext("Role")}
          options={[{gettext("Editor"), "editor"}, {gettext("Viewer"), "viewer"}]}
        />
        <.button type="submit" variant="secondary">{gettext("Invite")}</.button>
      </.form>
    </section>
    """
  end

  attr :project, :map, required: true
  attr :id, :string, required: true
  attr :editable, :boolean, required: true
  attr :uploads, :any, required: true
  attr :saved, :map, required: true

  defp images(assigns) do
    ~H"""
    <section class="card space-y-4" aria-labelledby="images-title" id="images">
      <h2 id="images-title" class="text-2xl">{gettext("Images")}</h2>
      <ul class="grid gap-4 sm:grid-cols-2">
        <li :for={image <- @project["images"]} id={"image-#{image["id"]}"} class="space-y-2">
          <img src={~p"/studio/#{@id}/images/#{image["id"]}"} alt={image["alt"]} class="studio-thumb" />
          <span :if={image["source"] == "demo"} class="studio-demo-chip">{gettext(
            "DEMO MODE — not a real AI"
          )}</span>
          <.form
            for={%{}}
            id={"image-form-#{image["id"]}"}
            phx-change="save_image"
            phx-submit="save_image"
          >
            <input type="hidden" name="image_id" value={image["id"]} />
            <input type="hidden" name="lesson_id" value={image["lesson_id"]} />
            <.input
              id={"alt-#{image["id"]}"}
              name="alt"
              value={image["alt"]}
              label={gettext("Text alternative")}
              hint={gettext("Describe the image for learners who can't see it.")}
              maxlength="300"
              phx-debounce="800"
              disabled={!@editable}
            />
            <.saved_status id={"image-saved-#{image["id"]}"} state={@saved["image:" <> image["id"]]} />
          </.form>
          <.button
            :if={@editable}
            variant="ghost"
            phx-click="delete_image"
            phx-value-id={image["id"]}
            data-confirm={gettext("Delete this image?")}
          >
            {gettext("Delete")}
          </.button>
        </li>
      </ul>
      <.form
        :if={@editable}
        for={%{}}
        id="upload-form"
        phx-change="validate_upload"
        phx-submit="upload_image"
        class="space-y-3"
      >
        <div class="field">
          <label for={@uploads.image.ref} class="label">{gettext(
            "Add an image (PNG, JPEG or WebP, 2 MB at most)"
          )}</label>
          <.live_file_input upload={@uploads.image} class="input" />
          <p :for={entry <- @uploads.image.entries} class="field-hint">
            {entry.client_name}
            <span :for={err <- upload_errors(@uploads.image, entry)} class="text-danger">
              {if err == :too_large,
                do: gettext("Too large (2 MB at most)."),
                else: gettext("Not a PNG, JPEG or WebP image.")}
            </span>
          </p>
        </div>
        <.input
          id="upload-alt"
          name="alt"
          value=""
          label={gettext("Text alternative (required)")}
          maxlength="300"
          required
        />
        <.input
          id="upload-lesson"
          name="lesson_id"
          value=""
          type="select"
          label={gettext("Lesson (optional)")}
          prompt={gettext("Whole project")}
          options={
            for l <- Enum.flat_map(@project["modules"], & &1["lessons"]), do: {l["title"], l["id"]}
          }
        />
        <.button type="submit" variant="secondary" id="upload-image">{gettext("Upload")}</.button>
      </.form>
    </section>
    """
  end

  attr :project, :map, required: true
  attr :owner, :boolean, required: true
  attr :editable, :boolean, required: true

  defp attestations(assigns) do
    assigns = assign(assigns, :values, assigns.project["attestations"] || %{})

    ~H"""
    <section class="card space-y-4" aria-labelledby="attestations-title" id="attestations">
      <h2 id="attestations-title" class="text-2xl">{gettext("Author's declarations")}</h2>
      <p class="text-sm text-muted">
        {gettext(
          "These are declarations made by the author, not automatic checks. They apply to the current content only: any change asks you to confirm them again."
        )}
      </p>
      <.form for={%{}} as={:attest} id="attest-form" phx-change="attest">
        <fieldset class="space-y-2" disabled={!(@owner and @editable)}>
          <label
            :for={
              {key, label} <- [
                {"accuracy", gettext("I checked that the content is accurate.")},
                {"safety", gettext("The content is safe and kind for its audience.")},
                {"accessibility",
                 gettext("Images have text alternatives and the text is clear for everyone.")}
              ]
            }
            class="choice"
          >
            <input type="hidden" name={"attest[#{key}]"} value="false" />
            <input
              type="checkbox"
              name={"attest[#{key}]"}
              value="true"
              checked={@values[key] == true}
              id={"attest-#{key}"}
            />
            <span>{label}</span>
          </label>
        </fieldset>
      </.form>
      <p
        :if={@project["attestations"]}
        id="attestations-state"
        class={["text-sm", if(@values["valid"], do: "text-success", else: "text-danger")]}
      >
        {if @values["valid"],
          do: gettext("Declarations confirmed for the current content."),
          else:
            gettext(
              "The content changed since your declarations (or one is missing): confirm them again."
            )}
      </p>
    </section>
    """
  end

  attr :versions, :any, required: true
  attr :editable, :boolean, required: true

  defp versions(assigns) do
    ~H"""
    <section class="card space-y-4" aria-labelledby="versions-title" id="versions">
      <h2 id="versions-title" class="text-2xl">{gettext("Versions")}</h2>
      <p class="text-sm text-muted">
        {gettext("Versions never change. Restoring one creates a new version, so nothing is lost.")}
      </p>
      <.form
        :if={@editable}
        for={%{}}
        id="version-form"
        phx-submit="save_version"
        class="studio-inline-form"
      >
        <.input
          id="version-note"
          name="note"
          value=""
          label={gettext("Note (optional)")}
          maxlength="200"
        />
        <.button type="submit" variant="secondary">{gettext("Save a version")}</.button>
      </.form>
      <%= case @versions do %>
        <% [_ | _] = versions -> %>
          <ol class="space-y-2">
            <li
              :for={v <- versions}
              id={"version-#{v["number"]}"}
              class="flex flex-wrap items-center gap-2"
            >
              <span class="font-medium text-ink">{gettext("Version %{n}", n: v["number"])}</span>
              <span class="text-sm text-muted">{v["note"]} · {version_source(v["source"])} · {date(
                v["inserted_at"]
              )}</span>
              <.button
                :if={@editable}
                variant="ghost"
                phx-click="restore_version"
                phx-value-id={v["id"]}
                id={"restore-#{v["number"]}"}
                data-confirm={
                  gettext("Replace the current content by this version? (A new version is created.)")
                }
              >
                {gettext("Restore")}
              </.button>
            </li>
          </ol>
        <% :unavailable -> %>
          <.unavailable>{gettext("Versions can't be loaded right now.")}</.unavailable>
        <% _ -> %>
          <p class="text-sm text-muted">{gettext("No version saved yet.")}</p>
      <% end %>
    </section>
    """
  end

  defp ai_panel(assigns) do
    ~H"""
    <section class="card space-y-4" id="ai-panel" aria-labelledby="ai-title">
      <h2 id="ai-title" class="text-2xl">{gettext("AI assistant")}</h2>
      <%= case @ai do %>
        <% :unavailable -> %>
          <.unavailable>{gettext("The AI assistant can't be reached right now.")}</.unavailable>
        <% ai -> %>
          <.notice
            :if={ai["demo"]}
            id="demo-mode"
            kind="reward"
            title={gettext("DEMO MODE — not a real AI")}
          >
            {gettext(
              "Suggestions are built from your text by simple rules on this server. No artificial intelligence is involved."
            )}
          </.notice>
          <.notice :if={!ai["configured"]} id="ai-not-configured" kind="warning">
            {gettext("AI generation is not configured on this server.")}
          </.notice>
          <p :if={ai["external"] and ai["configured"]} class="text-sm text-muted">
            {gettext("Generations are made by %{provider} (%{model}).",
              provider: "Anthropic Claude",
              model: ai["model"]
            )}
          </p>
          <form :if={ai["external"]} phx-change="consent" id="consent-form" class="choice">
            <input type="hidden" name="share" value="false" />
            <input
              type="checkbox"
              name="share"
              value="true"
              id="consent"
              checked={ai["share_drafts_with_ai"]}
            />
            <label for="consent">{gettext(
              "Share my drafts with the external AI provider (otherwise only the brief I type for each generation is sent)."
            )}</label>
          </form>
          <div :if={@editable and ai["configured"]} class="flex flex-col gap-2">
            <.button
              :if={@step == "outline"}
              phx-click="prepare"
              phx-value-kind="outline"
              id="ai-outline"
            >
              <.icon name="hero-sparkles" /> {gettext("Suggest an outline (%{n} credits)",
                n: ai["costs"]["outline"]
              )}
            </.button>
            <.button
              :if={@step == "build" and @lesson}
              phx-click="prepare"
              phx-value-kind="lesson_draft"
              phx-value-lesson_id={@lesson["id"]}
              id="ai-draft"
            >
              <.icon name="hero-sparkles" /> {gettext("Draft this lesson (%{n} credits)",
                n: ai["costs"]["lesson_draft"]
              )}
            </.button>
            <.button
              :if={(@step == "build" and @lesson) && @lesson["kind"] == "exercise"}
              variant="secondary"
              phx-click="prepare"
              phx-value-kind="feedback"
              phx-value-lesson_id={@lesson["id"]}
              id="ai-feedback"
            >
              {gettext("Improve the feedback (%{n} credits)", n: ai["costs"]["feedback"])}
            </.button>
            <.button
              :if={@step == "build" and ai["image_generation"]}
              variant="secondary"
              phx-click="prepare"
              phx-value-kind="image"
              phx-value-lesson_id={@lesson && @lesson["id"]}
              id="ai-image"
            >
              {gettext("Generate an image (%{n} credits, VIP)", n: ai["costs"]["image"])}
            </.button>
          </div>
      <% end %>
      <div class="space-y-3" id="generations" aria-live="polite">
        <.generation_card
          :for={g <- @generations}
          generation={g}
          editable={@editable}
          project_id={@id}
        />
      </div>
      <.link navigate={~p"/studio/credits"} class="link text-sm">{gettext("AI credits and history")}</.link>
    </section>
    """
  end

  attr :confirm, :map, required: true
  attr :ai, :any, required: true
  attr :credits, :any, required: true

  defp confirm_dialog(assigns) do
    assigns = assign(assigns, balance: balance(assigns.credits))

    ~H"""
    <dialog
      id="confirm-generation"
      class="studio-dialog card space-y-4"
      aria-labelledby="confirm-title"
      phx-hook="ModalDialog"
      data-cancel="close_confirm"
      data-return-focus
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <h2 id="confirm-title" class="text-2xl">
        {gettext("Confirm: %{kind}", kind: generation_label(@confirm.kind))}
      </h2>
      <.notice :if={@confirm[:error]} id="confirm-error" kind="danger" role="alert">
        {@confirm.error}
      </.notice>
      <p id="confirm-cost" class="font-medium text-ink">
        {ngettext("This uses %{count} credit.", "This uses %{count} credits.", @confirm.cost || 0)}
        <span :if={@balance}>{gettext("You have %{n} left this month.", n: @balance)}</span>
      </p>
      <p class="text-sm text-muted">
        {gettext(
          "Credits are only used if the generation succeeds: a failure or a cancellation refunds them."
        )}
      </p>
      <p :if={is_map(@ai) and @ai["external"]} class="text-sm text-muted">
        {if @ai["share_drafts_with_ai"],
          do:
            gettext(
              "This text and your project's content are sent to the AI provider (you agreed to share your drafts)."
            ),
          else: gettext("Only the text below is sent to the AI provider: your drafts are not shared.")}
      </p>
      <.form for={%{}} id="confirm-form" phx-submit="confirm_generation" class="space-y-3">
        <.input
          id="confirm-brief"
          name="brief"
          value={@confirm.brief}
          type="textarea"
          rows="4"
          maxlength="2000"
          label={gettext("Brief for this generation")}
          readonly={@confirm.retry_of != nil}
          required
        />
        <div class="flex flex-wrap gap-2">
          <.button type="submit" id="confirm-generate" phx-disable-with={gettext("Starting…")}>
            {ngettext(
              "Use %{count} credit and generate",
              "Use %{count} credits and generate",
              @confirm.cost || 0
            )}
          </.button>
          <.button type="button" variant="ghost" phx-click="close_confirm" id="close-confirm">{gettext(
            "Cancel"
          )}</.button>
        </div>
      </.form>
    </dialog>
    """
  end

  attr :form, :any, required: true

  defp sim_editor(assigns) do
    ~H"""
    <.input
      field={@form[:model]}
      type="select"
      label={gettext("Model (computed by the server)")}
      options={[
        {gettext("Orbit: a planet around its star (Verlet integration)"), "orbit"},
        {gettext("Reaction: balance an equation, then a chain of passes"), "reaction"}
      ]}
    />
    <.input
      field={@form[:goal_text]}
      type="textarea"
      rows="2"
      label={gettext("Goal shown to learners")}
      maxlength="500"
      phx-debounce="800"
    />
    <%= if @form[:model].value == "reaction" do %>
      <.input
        field={@form[:species]}
        type="textarea"
        rows="4"
        label={gettext("Species, one per line: formula, reactant or product, initial amount (mol)")}
        hint={
          gettext(
            "For example: H2, reactant, 10. Simple formulas only (no parentheses), 2 to 6 species."
          )
        }
        phx-debounce="800"
      />
      <div class="studio-grid-3">
        <.input
          field={@form[:max_coefficient]}
          type="number"
          min="1"
          max="12"
          label={gettext("Largest coefficient (1 to 12)")}
          phx-debounce="800"
        />
        <.input
          field={@form[:yield_pct]}
          type="number"
          min="1"
          max="100"
          label={gettext("Yield per pass (%)")}
          phx-debounce="800"
        />
        <.input
          field={@form[:steps]}
          type="number"
          min="1"
          max="100"
          label={gettext("Passes in the chain (1 to 100)")}
          phx-debounce="800"
        />
      </div>
      <input type="hidden" name="lesson[lowest_terms]" value="false" />
      <label class="choice" for="lowest-terms">
        <input
          type="checkbox"
          id="lowest-terms"
          name="lesson[lowest_terms]"
          value="true"
          checked={@form[:lowest_terms].value == "true"}
        />
        <span>{gettext("Require the smallest whole numbers (2 H2 + O2, not 4 H2 + 2 O2)")}</span>
      </label>
    <% else %>
      <fieldset
        :for={
          {prefix, legend} <- [
            {"velocity", gettext("Launch speed (AU/yr), bounds for learners")},
            {"star_mass", gettext("Star mass (M☉), bounds for learners")}
          ]
        }
        class="space-y-2"
      >
        <legend class="label">{legend}</legend>
        <div class="studio-grid-4">
          <.input
            :for={
              {key, label} <- [
                {"min", gettext("Minimum")},
                {"max", gettext("Maximum")},
                {"step", gettext("Step")},
                {"default", gettext("Start value")}
              ]
            }
            field={@form[:"#{prefix}_#{key}"]}
            type="number"
            step="any"
            label={label}
            phx-debounce="800"
          />
        </div>
      </fieldset>
      <div class="studio-grid-3">
        <.input
          field={@form[:distance]}
          type="number"
          step="any"
          label={gettext("Starting distance (AU, 0.1 to 10)")}
          phx-debounce="800"
        />
        <.input
          field={@form[:dt]}
          type="number"
          step="any"
          label={gettext("Time step (years, 0.0001 to 0.02)")}
          phx-debounce="800"
        />
        <.input
          field={@form[:steps]}
          type="number"
          min="10"
          max="20000"
          label={gettext("Steps (10 to 20,000)")}
          phx-debounce="800"
        />
      </div>
      <fieldset class="space-y-2">
        <legend class="label">{gettext("Objective (kept on the server)")}</legend>
        <div class="studio-grid-3">
          <.input
            field={@form[:max_eccentricity]}
            type="number"
            step="any"
            label={gettext("Largest eccentricity (0.001 to 0.5)")}
            phx-debounce="800"
          />
          <.input
            field={@form[:min_revolutions]}
            type="number"
            min="1"
            max="10"
            label={gettext("Full orbits required (1 to 10)")}
            phx-debounce="800"
          />
        </div>
      </fieldset>
    <% end %>
    """
  end

  attr :form, :any, required: true

  defp game_editor(assigns) do
    ~H"""
    <.input
      field={@form[:game]}
      type="select"
      label={gettext("Game")}
      options={[
        {gettext("Sequence: put items back in order"), "sequence"},
        {gettext("Constellation: link stars in order"), "constellation"}
      ]}
    />
    <.input
      field={@form[:prompt]}
      type="textarea"
      rows="2"
      label={gettext("Instructions shown to learners")}
      maxlength="500"
      phx-debounce="800"
    />
    <%= if @form[:game].value == "constellation" do %>
      <.input
        field={@form[:stars]}
        type="textarea"
        rows="6"
        label={gettext("Stars, one per line: name, x, y")}
        hint={gettext("x and y from 0 to 100 (y downwards), 3 to 12 stars. Extra stars are decoys.")}
        phx-debounce="800"
      />
      <.input
        field={@form[:path]}
        type="textarea"
        rows="5"
        label={gettext("The path to trace: star names in order, one per line")}
        hint={gettext("A star may come back later to close a shape (2 to 20 names).")}
        phx-debounce="800"
      />
    <% else %>
      <.input
        field={@form[:items]}
        type="textarea"
        rows="6"
        label={gettext("Items in the CORRECT order, one per line (3 to 10)")}
        hint={
          gettext("Learners get them shuffled; the order is checked by the server and never shown.")
        }
        phx-debounce="800"
      />
    <% end %>
    """
  end

  attr :lesson, :map, required: true
  attr :project, :map, required: true
  attr :id, :string, required: true
  attr :editable, :boolean, required: true
  attr :uploads, :any, required: true

  defp video_media(assigns) do
    media = Map.new(assigns.project["media"] || [], &{&1["id"], &1})
    content = assigns.lesson["content"] || %{}

    assigns =
      assign(assigns,
        video: media[content["video_id"]],
        captions: content["captions"] || [],
        languages: @languages
      )

    ~H"""
    <section
      class="space-y-4 border-t border-line pt-4"
      id="video-media"
      aria-labelledby="video-media-title"
    >
      <h3 id="video-media-title" class="text-2xl">{gettext("Video and captions")}</h3>
      <%= if @video do %>
        <p id="video-current" class="text-sm text-muted">
          {gettext("Current video: %{type}, %{size} MB",
            type: @video["content_type"],
            size: Float.round(@video["byte_size"] / 1_048_576, 1)
          )}
        </p>
        <video
          id="video-preview"
          class="lesson-video"
          controls
          preload="metadata"
          src={~p"/studio/#{@id}/media/#{@video["id"]}"}
        >
          <track
            :for={c <- @captions}
            kind="captions"
            src={~p"/studio/#{@id}/media/#{c["media_id"]}"}
            srclang={c["lang"]}
            label={c["label"]}
          />
        </video>
      <% else %>
        <p id="video-missing" class="text-muted">{gettext("No video yet.")}</p>
      <% end %>
      <.form
        :if={@editable}
        for={%{}}
        id="video-upload-form"
        phx-change="validate_upload"
        phx-submit="upload_video"
        class="studio-inline-form"
      >
        <div class="field">
          <label for={@uploads.video.ref} class="label">{gettext(
            "Upload the video (WebM or MP4, 50 MB at most)"
          )}</label>
          <.live_file_input upload={@uploads.video} class="input" />
          <p :for={entry <- @uploads.video.entries} class="field-hint">
            {entry.client_name} · {entry.progress}%
            <span :for={err <- upload_errors(@uploads.video, entry)} class="text-danger">
              {if err == :too_large,
                do: gettext("The file is larger than 50 MB."),
                else: gettext("Not a WebM or MP4 video.")}
            </span>
          </p>
        </div>
        <.button type="submit" variant="secondary" id="upload-video">{gettext("Upload")}</.button>
      </.form>

      <h4 class="text-xl">{gettext("Captions (WebVTT)")}</h4>
      <p :if={@captions == []} id="captions-missing" class="text-muted">
        {gettext("No caption track yet: at least one is required to publish.")}
      </p>
      <ul :if={@captions != []} id="captions-list" class="space-y-2">
        <li
          :for={c <- @captions}
          id={"captions-#{c["lang"]}"}
          class="flex flex-wrap items-center gap-2"
        >
          <a href={~p"/studio/#{@id}/media/#{c["media_id"]}"} class="link">{c["label"]}</a>
          <span class="text-sm text-muted">({c["lang"]})</span>
          <.button
            :if={@editable}
            type="button"
            variant="ghost"
            phx-click="delete_captions"
            phx-value-lang={c["lang"]}
            id={"delete-captions-#{c["lang"]}"}
            data-confirm={gettext("Remove this caption track?")}
          >
            {gettext("Remove")}
          </.button>
        </li>
      </ul>
      <.form
        :if={@editable}
        for={%{}}
        id="captions-form"
        phx-change="validate_upload"
        phx-submit="upload_captions"
        class="space-y-3"
      >
        <div class="studio-grid-3">
          <.input
            id="captions-lang"
            name="lang"
            value="en"
            type="select"
            label={gettext("Language")}
            options={for {code, name} <- @languages, do: {name, code}}
          />
          <.input
            id="captions-label"
            name="label"
            value=""
            label={gettext("Track name (optional)")}
            maxlength="40"
          />
          <div class="field">
            <label for={@uploads.captions.ref} class="label">{gettext(
              "WebVTT file (.vtt, 256 KB at most)"
            )}</label>
            <.live_file_input upload={@uploads.captions} class="input" />
            <p :for={entry <- @uploads.captions.entries} class="field-hint">
              {entry.client_name}
              <span :for={_err <- upload_errors(@uploads.captions, entry)} class="text-danger">{gettext(
                "The file is larger than 256 KB."
              )}</span>
            </p>
          </div>
        </div>
        <.button type="submit" variant="secondary" id="upload-captions">{gettext("Add the captions")}</.button>
      </.form>
    </section>
    """
  end
end
