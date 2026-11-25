defmodule MysticWeb.Offline do
  @moduledoc """
  Server side of the offline lessons: packages, synchronization of the queued actions and translated texts.
  """
  use Gettext, backend: MysticWeb.Gettext
  alias MysticWeb.{Api, Format, LessonContent}

  # durée maximale d'un paquet : la valeur de learning (`MlLearning.Offline.max_days/0`), fixée par le contrat
  @max_days 14
  @max_actions 50
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  def max_days, do: @max_days
  def max_actions, do: @max_actions

  @doc "Asks the browser to delete the premium copies it keeps (`ml:offline-purge`), with the explanation to show."
  def push_purge(socket, ended_at),
    do:
      Phoenix.LiveView.push_event(socket, "ml:offline-purge", %{message: ended_message(ended_at)})

  @doc "« Your Premium access ended on … »: why the offline copies were deleted."
  def ended_message(at) when is_binary(at),
    do:
      gettext(
        "Your Premium access ended on %{date}: the premium lessons kept on this device for offline reading were deleted.",
        date: Format.date(at)
      )

  def ended_message(_at),
    do:
      gettext(
        "Your Premium access has ended: the premium lessons kept on this device for offline reading were deleted."
      )

  ## Paid access

  @doc """
  `{:ok, true}` while billing reports a paid plan in effect, `{:ok, false, message}` once it ended (the message says
  when), `:unknown` when billing doesn't answer (nothing is deleted on a guess).
  """
  def paid_access(user) do
    case Api.get(nil, :billing, "/api/entitlements/:id", path_params: [id: Api.user_id(user)]) do
      {:ok, %{"plan" => plan, "status" => status}}
      when plan in ~w(premium vip) and status in ~w(active past_due) ->
        {:ok, true}

      {:ok, %{"plan" => _} = entitlements} ->
        {:ok, false, ended_message(ended_at(entitlements))}

      _ ->
        :unknown
    end
  end

  defp ended_at(entitlements) do
    case MysticWeb.AccessComponents.access_end(entitlements) do
      {:ended, at} -> at
      :none -> nil
    end
  end

  @doc "Signed-in member, CSRF token and paid access, for the offline page and the synchronization."
  def session(user, csrf_token) do
    {premium, message} =
      case paid_access(user) do
        {:ok, true} -> {true, nil}
        {:ok, false, message} -> {false, message}
        :unknown -> {nil, nil}
      end

    %{member_id: user["id"], csrf_token: csrf_token, premium: premium, message: message}
  end

  ## Package

  @doc "`{:ok, package}` or `{:error, status, %{error, message}}`."
  def package(user, lesson_id) do
    case Api.get(user, :learning, "/api/lessons/:id/offline", path_params: [id: lesson_id]) do
      {:ok, %{"package" => %{"lesson" => %{"id" => _, "kind" => kind} = lesson} = package}}
      when kind in ~w(story exercise) ->
        {:ok,
         %{
           format: 1,
           member_id: package["member_id"],
           lesson_id: lesson["id"],
           kind: kind,
           title: lesson["title"],
           xp_reward: lesson["xp_reward"],
           revision: lesson["revision"],
           revised_at: lesson["revised_at"],
           adventure: package["adventure"],
           html: LessonContent.fragment(lesson),
           downloaded_at: package["downloaded_at"],
           expires_at: package["expires_at"],
           expires_by: package["expires_by"],
           max_days: package["max_days"]
         }}

      {:ok, _unexpected} ->
        {:error, 503, error(:unavailable, Api.error_message({:error, :unavailable}))}

      {:error, {:http, status, body}} ->
        {:error, status, package_error(status, Api.error_code({:error, {:http, status, body}}))}

      {:error, reason} ->
        {:error, 503, error(:unavailable, Api.error_message({:error, reason}))}
    end
  end

  defp package_error(402, _),
    do:
      error(
        :premium_required,
        gettext("Offline copies come with a Premium or VIP membership that is in effect.")
      )

  defp package_error(409, "no_paid_period"),
    do:
      error(
        :no_paid_period,
        gettext(
          "Offline copies need a paid period in progress, and yours has ended or isn't known yet (a late payment, for example). Online lessons still work."
        )
      )

  defp package_error(422, _),
    do:
      error(
        :offline_unavailable,
        gettext("Only the stories and quizzes of Premium adventures can be kept offline.")
      )

  defp package_error(404, _), do: error(:not_found, gettext("This lesson doesn't exist anymore."))
  defp package_error(status, code), do: error(code || :error, status_message(status, code))

  defp status_message(status, code),
    do: Api.error_message({:error, {:http, status, %{"error" => code}}})

  defp error(code, message), do: %{error: code, message: message}

  ## Synchronization

  @doc "Replays at most #{@max_actions} queued actions as `user` and reports the result of each one."
  def sync(user, actions) when is_list(actions) do
    {results, purge} =
      actions
      |> Enum.take(@max_actions)
      |> Enum.map_reduce(nil, fn action, purge -> replay(user, action, purge) end)

    %{results: results, purge: purge}
  end

  # access already found ended: the following actions are refused without asking again
  defp replay(_user, action, %{message: message} = purge),
    do: {refused(action, "access_ended", access_title(), message), purge}

  defp replay(user, action, nil) do
    case validate(action) do
      {:ok, action} ->
        case call(user, action) do
          {:ok, body} ->
            {done(action, body), nil}

          {:error, {:http, 402, _}} ->
            message =
              case paid_access(user) do
                {:ok, false, message} -> message
                _ -> ended_message(nil)
              end

            {refused(action, "access_ended", access_title(), message), %{message: message}}

          error ->
            {failed(action, error), nil}
        end

      :error ->
        {refused(action, "invalid", gettext("Not checked"), invalid_message()), nil}
    end
  end

  defp validate(%{"key" => key, "lesson_id" => lesson_id, "kind" => kind} = action)
       when is_binary(key) and is_binary(lesson_id) and kind in ~w(submit complete) do
    revision = action["revision"]
    answer = action["answer"]

    cond do
      not (key =~ @uuid and lesson_id =~ @uuid) ->
        :error

      not (is_integer(revision) and revision > 0) ->
        :error

      kind == "submit" and not (is_binary(answer) and answer != "" and byte_size(answer) <= 2000) ->
        :error

      true ->
        {:ok, %{key: key, lesson_id: lesson_id, kind: kind, answer: answer, revision: revision}}
    end
  end

  defp validate(_action), do: :error

  defp call(user, %{kind: "submit"} = action),
    do:
      Api.post(user, :learning, "/api/lessons/:id/submit",
        path_params: [id: action.lesson_id],
        json: %{answer: action.answer, idempotency_key: action.key, revision: action.revision}
      )

  defp call(user, %{kind: "complete"} = action),
    do:
      Api.post(user, :learning, "/api/lessons/:id/complete",
        path_params: [id: action.lesson_id],
        json: %{idempotency_key: action.key, revision: action.revision}
      )

  defp done(action, body) do
    replayed = body["replayed"] == true
    correct = if action.kind == "submit", do: body["correct"] == true

    title =
      case {action.kind, correct} do
        {"complete", _} -> gettext("Marked as read")
        {_, true} -> gettext("Well done!")
        _ -> gettext("Not quite — try again")
      end

    xp_text =
      cond do
        replayed -> gettext("Already synchronized earlier: nothing was counted twice.")
        body["xp"] == "awarded" -> gettext("+%{xp} XP", xp: body["xp_reward"])
        body["xp"] == "duplicate" -> gettext("Already completed — XP granted once.")
        true -> nil
      end

    %{
      key: action.key,
      lesson_id: action.lesson_id,
      status: "done",
      correct: correct,
      xp: body["xp"],
      replayed: replayed,
      title: title,
      message: body["feedback"],
      xp_text: xp_text
    }
  end

  defp failed(action, {:error, {:http, 409, %{"error" => "lesson_changed"}}}),
    do:
      refused(
        action,
        "lesson_changed",
        gettext("Not checked: the lesson changed"),
        gettext(
          "This lesson was updated after you downloaded it. Your answer wasn't checked against a different statement: open the lesson again to answer its current version."
        )
      )

  defp failed(action, {:error, {:http, 404, _}}),
    do:
      refused(
        action,
        "not_found",
        gettext("Not checked"),
        gettext("This lesson doesn't exist anymore.")
      )

  defp failed(action, {:error, {:http, status, _}} = error) when status in [400, 409, 422],
    do: refused(action, "invalid", gettext("Not checked"), Api.error_message(error))

  defp failed(action, error),
    do: %{
      key: action.key,
      lesson_id: action.lesson_id,
      status: "retry",
      reason: "unavailable",
      title: gettext("Still waiting"),
      message:
        gettext(
          "The academy can't check answers right now (%{reason}). Your answer stays waiting on this device and will be sent again.",
          reason: Api.error_message(error)
        )
    }

  defp refused(action, reason, title, message),
    do: %{
      key: action_key(action),
      lesson_id: action_lesson(action),
      status: "refused",
      reason: reason,
      title: title,
      message: message
    }

  defp action_key(%{key: key}), do: key
  defp action_key(%{"key" => key}) when is_binary(key), do: key
  defp action_key(_), do: nil

  defp action_lesson(%{lesson_id: id}), do: id
  defp action_lesson(%{"lesson_id" => id}) when is_binary(id), do: id
  defp action_lesson(_), do: nil

  defp access_title, do: gettext("Not checked: your Premium access ended")

  defp invalid_message,
    do: gettext("This saved answer is incomplete or damaged, so it can't be checked.")

  ## Texts of the browser views

  @doc "Translated texts of the offline views, JSON-encoded in a `data-texts` attribute."
  def texts(view) when view in [:lesson, :settings, :shell],
    do: Map.merge(common_texts(), view_texts(view))

  defp common_texts do
    %{
      kind_story: Format.kind_label("story"),
      kind_exercise: Format.kind_label("exercise"),
      expires: gettext("Available offline until %{date}", date: "%{date}"),
      downloaded: gettext("Downloaded on %{date}", date: "%{date}"),
      size: gettext("Size on this device: %{size}", size: "%{size}"),
      version: gettext("Version %{revision} of the lesson", revision: "%{revision}"),
      pending_tag: gettext("Waiting for synchronization"),
      pending_count: gettext("Waiting for synchronization: %{count}", count: "%{count}"),
      offline_now: gettext("You're offline."),
      online_now: gettext("You're online."),
      sync_now: gettext("Synchronize now"),
      syncing: gettext("Synchronizing…"),
      sync_offline_reason:
        gettext(
          "Synchronization needs a connection: it starts by itself when the connection is back."
        ),
      sync_done: gettext("Synchronization finished."),
      sync_nothing: gettext("Nothing is waiting for synchronization."),
      sync_signed_out:
        gettext(
          "Log in to synchronize: your answers stay on this device until then (they are only sent for the member who gave them)."
        ),
      sync_error:
        gettext(
          "The synchronization didn't finish: your answers stay waiting on this device and will be sent again."
        ),
      sync_busy: gettext("A synchronization is already running in another tab."),
      remove: gettext("Remove from this device"),
      removed: gettext("“%{title}” was removed from this device.", title: "%{title}"),
      expired_removed:
        gettext("“%{title}” expired and was removed from this device.", title: "%{title}"),
      unsupported: gettext("This browser can't keep lessons for offline reading."),
      last_results: gettext("Last synchronization"),
      result_at: gettext("Checked on %{date}", date: "%{date}"),
      purge_generic: ended_message(nil)
    }
  end

  defp view_texts(:lesson) do
    %{
      checking: gettext("Checking this device…"),
      download: gettext("Make available offline"),
      download_again: gettext("Download again"),
      downloading: gettext("Downloading…"),
      downloaded_ok:
        gettext(
          "Available offline until %{date}: open it from the offline page, even without a connection.",
          date: "%{date}"
        ),
      outdated:
        gettext(
          "This lesson changed since you downloaded it: download it again to read its current version offline."
        ),
      need_connection: gettext("Downloading needs a connection."),
      download_failed:
        gettext("The download didn't finish, nothing was kept. Please try again in a moment.")
    }
  end

  defp view_texts(:settings) do
    %{
      empty: gettext("No lesson is kept on this device for offline reading."),
      count_lessons: gettext("Lessons on this device: %{count}", count: "%{count}"),
      total_size: gettext("Space used on this device: %{size}", size: "%{size}"),
      clear: gettext("Clear offline data"),
      clearing: gettext("Clearing…"),
      clear_confirm:
        gettext(
          "Delete every offline lesson, every answer waiting for synchronization and the offline page from this device?"
        ),
      clear_confirm_pending:
        gettext(
          "Waiting for synchronization: %{count}. These answers were never checked and will be lost. Delete everything anyway?",
          count: "%{count}"
        ),
      cleared: gettext("Offline data deleted from this device."),
      open_shell: gettext("Open the offline page")
    }
  end

  defp view_texts(:shell) do
    %{
      empty:
        gettext(
          "No lesson is available offline on this device. When you're online, open a premium story or quiz and choose « Make available offline »."
        ),
      page_unavailable:
        gettext(
          "This page needs a connection: « %{path} » can't be shown offline. Your downloaded lessons are below.",
          path: "%{path}"
        ),
      not_found:
        gettext(
          "This lesson isn't available offline on this device: it was removed, it expired, or it was never downloaded."
        ),
      back_list: gettext("All offline lessons"),
      open_online: gettext("Open the online lesson"),
      online_only: gettext("Needs a connection"),
      copy_note:
        gettext(
          "Offline copy: it stays on this device until %{date}. Anyone using this device can read it.",
          date: "%{date}"
        ),
      answer_save: gettext("Save my answer"),
      answer_saved:
        gettext(
          "Answer saved on this device, waiting for synchronization. It is NOT checked yet: the server checks it when you're back online, and it counts on the day it is synchronized."
        ),
      answer_pending:
        gettext(
          "Your answer « %{answer} » is waiting for synchronization: you can answer again once it has been checked.",
          answer: "%{answer}"
        ),
      choose_first: gettext("Choose an answer first."),
      story_done: gettext("Mark as read"),
      story_saved:
        gettext(
          "Marked as read on this device, waiting for synchronization. It counts on the day it is synchronized."
        ),
      story_pending: gettext("Marked as read: waiting for synchronization."),
      wiped_other:
        gettext(
          "The offline data of the previous member was deleted from this device: another member is signed in."
        )
    }
  end
end
