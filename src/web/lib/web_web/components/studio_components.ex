defmodule MysticWeb.StudioComponents do
  @moduledoc "Studio components: workflow status, steps, autosave, AI generations, checks and preview."
  use Phoenix.Component
  use Gettext, backend: MysticWeb.Gettext
  import MysticWeb.CoreComponents
  import MysticWeb.MysticComponents, only: [tag: 1]
  alias MysticWeb.Api

  @steps ~w(brief outline build review publish)
  def steps, do: @steps

  ## Labels

  def step_label("brief"), do: gettext("Brief")
  def step_label("outline"), do: gettext("Outline")
  def step_label("build"), do: gettext("Build")
  def step_label("review"), do: gettext("Review")
  def step_label("publish"), do: gettext("Publish")

  def status_label("draft"), do: gettext("Draft")
  def status_label("submitted"), do: gettext("In review")
  def status_label("approved"), do: gettext("Approved")
  def status_label("published"), do: gettext("Published")
  def status_label(other), do: to_string(other)

  def role_label("owner"), do: gettext("Owner")
  def role_label("editor"), do: gettext("Editor")
  def role_label("viewer"), do: gettext("Viewer")
  def role_label(other), do: to_string(other)

  def generation_label("outline"), do: gettext("Outline")
  def generation_label("lesson_draft"), do: gettext("Lesson draft")
  def generation_label("feedback"), do: gettext("Feedback improvement")
  def generation_label("image"), do: gettext("Image")
  def generation_label(other), do: to_string(other)

  def generation_status("pending"), do: gettext("Queued")
  def generation_status("running"), do: gettext("Generating…")
  def generation_status("succeeded"), do: gettext("Ready")
  def generation_status("failed"), do: gettext("Failed")
  def generation_status("cancelled"), do: gettext("Cancelled")
  def generation_status(other), do: to_string(other)

  def credits_state("reserved"), do: gettext("credits reserved")
  def credits_state("consumed"), do: gettext("credits used")
  def credits_state("released"), do: gettext("credits refunded")
  def credits_state(_), do: ""

  def entry_label("allocation"), do: gettext("Monthly allocation")
  def entry_label("top_up"), do: gettext("Upgrade top-up")
  def entry_label("reservation"), do: gettext("Reserved")
  def entry_label("consumption"), do: gettext("Used")
  def entry_label("release"), do: gettext("Refunded")
  def entry_label("expiration"), do: gettext("Expired (end of month)")
  def entry_label("adjustment"), do: gettext("Granted by the team")
  def entry_label(other), do: to_string(other)

  def version_source("manual"), do: gettext("Saved by an author")
  def version_source("submission"), do: gettext("Submitted for review")
  def version_source("restore"), do: gettext("Restored")
  def version_source(other), do: to_string(other)

  def generation_error("not_configured"), do: gettext("The AI provider is not configured.")
  def generation_error("refused"), do: gettext("The AI provider declined this request.")
  def generation_error("truncated"), do: gettext("The answer was too long and was cut off.")
  def generation_error("invalid_output"), do: gettext("The answer couldn't be used.")

  def generation_error(code)
      when code in ["rate_limited", "overloaded", "provider_unavailable", "timeout"],
      do: gettext("The AI provider is busy or unreachable.")

  def generation_error(_code), do: gettext("The AI provider rejected the request.")

  def check_label("structure"), do: gettext("At least one module, and lessons in every module")
  def check_label("objectives"), do: gettext("Learning objectives")
  def check_label("titles"), do: gettext("Titles")
  def check_label("quizzes"), do: gettext("Valid quizzes")
  def check_label("grovescript"), do: gettext("Valid GroveScript puzzles")
  def check_label("image_alt"), do: gettext("Text alternatives for every image")
  def check_label("no_html"), do: gettext("No HTML or script")
  def check_label("lengths"), do: gettext("Lengths")
  def check_label("links"), do: gettext("Only http(s) links")
  def check_label("videos"), do: gettext("Videos with captions and a transcript")
  def check_label("simulations"), do: gettext("Valid simulations")
  def check_label("minigames"), do: gettext("Valid mini-games")
  def check_label(other), do: to_string(other)

  @doc "Translated message of a publication issue."
  def issue_message(%{"code" => code} = i) do
    where = where(i)
    field = field_label(i["field"])

    case code do
      "no_modules" ->
        gettext("Add at least one module.")

      "too_many_modules" ->
        gettext("Use at most 20 modules.")

      "empty_module" ->
        gettext("Module %{n} has no lesson yet.", n: i["module"])

      "too_many_lessons" ->
        gettext("Module %{n} has more than 30 lessons.", n: i["module"])

      "no_objectives" ->
        gettext("Add at least one learning objective.")

      "too_many_objectives" ->
        gettext("Use at most 10 objectives.")

      "objective" ->
        gettext("Objective %{n} is too long (200 characters max).", n: i["index"])

      "project_title" ->
        gettext("The project title needs 3 to 120 characters.")

      "module_title" ->
        gettext("Module %{n} needs a title of 120 characters at most.", n: i["module"])

      "lesson_title" ->
        gettext("%{where}: the title needs 1 to 120 characters.", where: where)

      "quiz_question" ->
        gettext("%{where}: write the question (500 characters max).", where: where)

      "quiz_choices" ->
        gettext("%{where}: give 2 to 6 different choices (200 characters max each).",
          where: where
        )

      "quiz_answer" ->
        gettext("%{where}: choose the correct answer.", where: where)

      "quiz_explanation" ->
        gettext("%{where}: explain the correct answer (1,000 characters max).", where: where)

      "grove_plants" ->
        gettext("%{where}: the puzzle needs 2 to 10 plants.", where: where)

      "grove_starter" ->
        gettext("%{where}: write a starter spell (600 bytes max).", where: where)

      "grove_hints" ->
        gettext("%{where}: give 1 to 5 hints (300 characters max each).", where: where)

      "video_file" ->
        gettext("%{where}: upload the video (WebM or MP4).", where: where)

      "video_captions" ->
        gettext("%{where}: add at least one WebVTT caption track.", where: where)

      "video_transcript" ->
        gettext("%{where}: write the full transcript.", where: where)

      "video_duration" ->
        gettext("%{where}: give the duration of the video (1 to 7,200 seconds).", where: where)

      "sim_model" ->
        gettext("%{where}: choose a model (orbit or reaction).", where: where)

      "sim_goal" ->
        gettext("%{where}: write the goal shown to learners (500 characters max).", where: where)

      "sim_steps" ->
        gettext("%{where}: the number of steps is outside the model's limits.", where: where)

      "sim_params" ->
        gettext(
          "%{where}: check the bounds: minimum below maximum, inside the model's limits, a step that divides the range, a start value on the grid.",
          where: where
        )

      "sim_species" ->
        gettext(
          "%{where}: give 2 to 6 different species with simple formulas (like H2O), at least one reactant and one product, initial amounts from 0 to 1,000 mol.",
          where: where
        )

      "sim_objective" ->
        gettext(
          "%{where}: the objective needs an eccentricity from 0.001 to 0.5 and 1 to 10 full orbits.",
          where: where
        )

      "game_type" ->
        gettext("%{where}: choose a game (sequence or constellation).", where: where)

      "game_prompt" ->
        gettext("%{where}: write the instructions (500 characters max).", where: where)

      "game_items" ->
        gettext("%{where}: give 3 to 10 different items (200 characters max each).", where: where)

      "game_stars" ->
        gettext(
          "%{where}: give 3 to 12 stars with different names and x, y from 0 to 100.",
          where: where
        )

      "game_path" ->
        gettext(
          "%{where}: the path needs 2 to 20 names of the stars, never the same star twice in a row.",
          where: where
        )

      "image_alt" ->
        gettext("An image has no text alternative yet.")

      "html" ->
        gettext("%{where}: remove the HTML or script from “%{field}”.",
          where: where,
          field: field
        )

      "summary" ->
        gettext("The summary needs 1 to 300 characters.")

      "description" ->
        gettext("The description is longer than 5,000 characters.")

      "duration" ->
        gettext("The duration must be between 5 and 600 minutes.")

      "body" ->
        gettext("%{where}: the lesson text is empty or too long.", where: where)

      "xp" ->
        gettext("%{where}: XP must be between 1 and 100.", where: where)

      "link" ->
        gettext("%{where}: only http(s) links are allowed (“%{field}”).",
          where: where,
          field: field
        )

      _ ->
        code
    end
  end

  defp where(%{"lesson" => lesson, "module" => module, "title" => title}) when is_integer(lesson),
    do: gettext("Module %{m}, lesson %{l} “%{title}”", m: module, l: lesson, title: title)

  defp where(%{"module" => module}) when is_integer(module), do: gettext("Module %{m}", m: module)
  defp where(%{"image" => image}) when is_binary(image), do: gettext("An image")
  defp where(_issue), do: gettext("The brief")

  defp field_label("title"), do: gettext("title")
  defp field_label("summary"), do: gettext("summary")
  defp field_label("description"), do: gettext("description")
  defp field_label("audience"), do: gettext("audience")
  defp field_label("objectives"), do: gettext("objectives")
  defp field_label("prerequisites"), do: gettext("prerequisites")
  defp field_label("module_title"), do: gettext("module title")
  defp field_label("body"), do: gettext("lesson text")
  defp field_label("question"), do: gettext("question")
  defp field_label("choices"), do: gettext("choices")
  defp field_label("explanation"), do: gettext("explanation")
  defp field_label("starter"), do: gettext("starter spell")
  defp field_label("hints"), do: gettext("hints")
  defp field_label("alt"), do: gettext("text alternative")
  defp field_label("transcript"), do: gettext("transcript")
  defp field_label("captions"), do: gettext("caption track name")
  defp field_label("goal_text"), do: gettext("goal")
  defp field_label("species"), do: gettext("species")
  defp field_label("prompt"), do: gettext("instructions")
  defp field_label("items"), do: gettext("items")
  defp field_label("stars"), do: gettext("stars")
  defp field_label("path"), do: gettext("path")
  defp field_label(other), do: to_string(other)

  @doc "Messages of the studio and credit error codes, else the generic ones of `MysticWeb.Api`."
  def error_message({:error, {:http, _status, %{"error" => code} = body}} = error) do
    case code do
      "insufficient_credits" ->
        gettext("Not enough AI credits: %{n} left this month.", n: body["balance"])

      "vip_required" ->
        gettext("Image generation is part of the VIP plan.")

      "image_generation_unavailable" ->
        gettext("Image generation is not available with the configured provider.")

      "ai_not_configured" ->
        gettext("AI generation is not configured on this server.")

      "cost_mismatch" ->
        gettext("The cost changed to %{n} credits: please confirm again.", n: body["cost"])

      "credits_unavailable" ->
        gettext("AI credits can't be checked right now. Nothing was charged.")

      "too_many_generations" ->
        gettext("Five generations are already running. Wait for one to finish.")

      "locked" ->
        gettext("This project is in review: it can't be changed until the review ends.")

      "blocked" ->
        gettext("This member can't be invited.")

      "user_not_found" ->
        gettext("No member has this username.")

      "already_collaborator" ->
        gettext("This member is already a collaborator.")

      "self" ->
        gettext("You already own this project.")

      "own_project" ->
        gettext("You are an author of this project: another moderator must review it.")

      "attestations_required" ->
        gettext("Confirm the three declarations for the current content first.")

      "checks_failed" ->
        gettext("Some automatic checks fail: fix them before submitting.")

      "already_applied" ->
        gettext("This result was already added to the project.")

      "target_missing" ->
        gettext("The lesson of this result no longer exists.")

      "too_many_images" ->
        gettext("A project can hold at most 30 images.")

      "too_many_modules" ->
        gettext("A project can hold at most 20 modules.")

      "too_many_lessons" ->
        gettext("A module can hold at most 30 lessons.")

      _ ->
        Api.error_message(error)
    end
  end

  def error_message(error), do: Api.error_message(error)

  ## Components

  attr :status, :string, required: true
  attr :id, :string, default: nil

  def status_tag(assigns) do
    ~H"""
    <.tag
      id={@id}
      kind={
        case @status do
          "published" -> "success"
          "approved" -> "premium"
          "submitted" -> "info"
          _ -> "neutral"
        end
      }
    >
      {status_label(@status)}
    </.tag>
    """
  end

  attr :project_id, :string, required: true
  attr :step, :string, required: true

  def step_nav(assigns) do
    ~H"""
    <nav aria-label={gettext("Steps")} class="studio-steps" id="studio-steps">
      <.link
        :for={{step, i} <- Enum.with_index(steps(), 1)}
        patch={"/studio/#{@project_id}?step=#{step}"}
        id={"step-#{step}"}
        class="studio-step"
        aria-current={@step == step && "step"}
      >
        <span class="studio-step-number" aria-hidden="true">{i}</span>
        <span>{step_label(step)}</span>
      </.link>
    </nav>
    """
  end

  @doc "Autosave status of one item: nothing yet, « Saved at hh:mm:ss <zone> » or the error."
  attr :state, :any, default: nil
  attr :id, :string, required: true

  def saved_status(assigns) do
    ~H"""
    <p id={@id} class="studio-saved" aria-live="polite">
      <%= case @state do %>
        <% {:ok, at} -> %>
          <span class="text-success">
            <.icon name="hero-check" class="size-4" />
            {gettext("Saved at %{time}", time: MysticWeb.Format.time(at, seconds: true))}
          </span>
        <% {:error, message} -> %>
          <span class="text-danger">{message}</span>
        <% _ -> %>
      <% end %>
    </p>
    """
  end

  attr :generation, :map, required: true
  attr :editable, :boolean, default: false
  attr :project_id, :string, required: true

  def generation_card(assigns) do
    ~H"""
    <article id={"generation-#{@generation["id"]}"} class="studio-generation">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <p class="font-medium text-ink">{generation_label(@generation["kind"])}</p>
        <.tag
          kind={
            case @generation["status"] do
              "succeeded" -> "success"
              "failed" -> "danger"
              "cancelled" -> "neutral"
              _ -> "info"
            end
          }
          id={"generation-#{@generation["id"]}-status"}
        >
          {generation_status(@generation["status"])}
        </.tag>
      </div>
      <p class="text-sm text-muted">
        {ngettext("%{count} credit", "%{count} credits", @generation["cost"])} · {credits_state(
          @generation["credits"]
        )}
        <span :if={@generation["demo"]} class="studio-demo-chip">{gettext("DEMO MODE — not a real AI")}</span>
      </p>
      <p :if={@generation["status"] == "failed"} class="text-sm text-danger">
        {generation_error(@generation["error"])}
      </p>
      <p :if={@generation["status"] == "pending" and @generation["error"]} class="text-sm text-muted">
        {gettext("Retrying soon: the provider was busy.")}
      </p>
      <div :if={@generation["status"] == "succeeded"} class="studio-result">
        <%= case @generation do %>
          <% %{"kind" => "outline", "result" => %{"modules" => modules}} -> %>
            <ol class="list-decimal space-y-1 pl-5 text-sm">
              <li :for={m <- modules}>
                {m["title"]}
                <span class="text-muted">
                  ({ngettext("%{count} lesson", "%{count} lessons", length(m["lessons"] || []))})
                </span>
              </li>
            </ol>
          <% %{"kind" => "image", "result" => %{"image_id" => image_id}} -> %>
            <img src={"/studio/#{@project_id}/images/#{image_id}"} alt="" class="studio-thumb" />
            <p class="text-sm text-muted">
              {gettext("Added to your images: write its text alternative.")}
            </p>
          <% %{"result" => %{"body" => body}} -> %>
            <p class="line-clamp-3 text-sm">{body}</p>
          <% %{"result" => %{"explanation" => text}} -> %>
            <p class="text-sm">{text}</p>
          <% _ -> %>
        <% end %>
      </div>
      <div :if={@editable} class="flex flex-wrap gap-2">
        <.button
          :if={@generation["status"] in ["pending", "running"]}
          variant="ghost"
          phx-click="cancel_generation"
          phx-value-id={@generation["id"]}
          id={"cancel-#{@generation["id"]}"}
        >
          {gettext("Cancel")}
        </.button>
        <.button
          :if={@generation["status"] in ["failed", "cancelled"]}
          variant="secondary"
          phx-click="prepare_retry"
          phx-value-id={@generation["id"]}
          id={"retry-#{@generation["id"]}"}
        >
          {gettext("Try again")}
        </.button>
        <.button
          :if={
            @generation["status"] == "succeeded" and @generation["kind"] != "image" and
              is_nil(@generation["applied_at"])
          }
          phx-click="apply_generation"
          phx-value-id={@generation["id"]}
          id={"apply-#{@generation["id"]}"}
        >
          {gettext("Add to the project")}
        </.button>
        <span :if={@generation["applied_at"]} class="text-sm text-muted">{gettext(
          "Added to the project."
        )}</span>
      </div>
    </article>
    """
  end

  attr :checks, :list, required: true

  def check_list(assigns) do
    ~H"""
    <ul class="space-y-3" id="checks">
      <li :for={check <- @checks} id={"check-#{check["key"]}"} class="studio-check">
        <p class="flex items-center gap-2 font-medium text-ink">
          <.icon
            name={if check["ok"], do: "hero-check-circle-solid", else: "hero-x-circle-solid"}
            class={["size-5", if(check["ok"], do: "text-success", else: "text-danger")]}
          />
          <span>{check_label(check["key"])}</span>
          <span class="sr-only">{if check["ok"], do: gettext("passed"), else: gettext("to fix")}</span>
        </p>
        <ul :if={check["issues"] != []} class="list-disc space-y-1 pl-10 text-sm text-muted">
          <li :for={issue <- check["issues"]}>{issue_message(issue)}</li>
        </ul>
      </li>
    </ul>
    """
  end

  @doc "Read-only rendering of a lesson as a learner sees it (the quiz answer is never shown)."
  attr :lesson, :map, required: true
  attr :project_id, :string, default: nil
  attr :images, :list, default: []

  def lesson_preview(assigns) do
    ~H"""
    <article class="studio-preview-lesson" id={"preview-#{@lesson["id"]}"}>
      <p class="eyebrow">
        {MysticWeb.Format.kind_label(@lesson["kind"])} · {gettext("%{xp} XP",
          xp: @lesson["xp_reward"]
        )}
      </p>
      <h4 class="text-2xl">{@lesson["title"]}</h4>
      <div class="story space-y-3">
        <p :for={paragraph <- String.split(@lesson["body"] || "", ~r/\n{2,}/, trim: true)}>
          {paragraph}
        </p>
      </div>
      <figure :for={image <- @images} class="space-y-1">
        <img
          src={"/studio/#{@project_id}/images/#{image["id"]}"}
          alt={image["alt"]}
          class="studio-thumb"
        />
      </figure>
      <%= case @lesson["kind"] do %>
        <% "exercise" -> %>
          <fieldset class="space-y-2" disabled>
            <legend class="font-medium text-ink">{@lesson["content"]["question"]}</legend>
            <label :for={choice <- @lesson["content"]["choices"] || []} class="choice">
              <input type="radio" disabled /> <span>{choice}</span>
            </label>
          </fieldset>
        <% "coding" -> %>
          <p class="text-sm text-muted">
            {ngettext(
              "A grove of %{count} plant to water with a loop.",
              "A grove of %{count} plants to water with a loop.",
              @lesson["content"]["plants"] || 0
            )}
          </p>
          <pre class="code-editor studio-code">{@lesson["content"]["starter"]}</pre>
          <ol
            :if={(@lesson["content"]["hints"] || []) != []}
            class="list-decimal pl-5 text-sm text-muted"
          >
            <li :for={hint <- @lesson["content"]["hints"]}>{hint}</li>
          </ol>
        <% "video" -> %>
          <video
            :if={@project_id && @lesson["content"]["video_id"]}
            class="lesson-video"
            controls
            preload="metadata"
            src={"/studio/#{@project_id}/media/#{@lesson["content"]["video_id"]}"}
          >
            <track
              :for={c <- @lesson["content"]["captions"] || []}
              kind="captions"
              src={"/studio/#{@project_id}/media/#{c["media_id"]}"}
              srclang={c["lang"]}
              label={c["label"]}
            />
          </video>
          <p class="text-sm text-muted">
            {ngettext(
              "A video with %{count} caption track and its transcript.",
              "A video with %{count} caption tracks and its transcript.",
              length(@lesson["content"]["captions"] || [])
            )}
          </p>
          <details class="faq">
            <summary>{gettext("Transcript")}</summary>
            <p class="whitespace-pre-line">{@lesson["content"]["transcript"]}</p>
          </details>
        <% "simulation" -> %>
          <p class="text-sm text-muted">
            {if @lesson["content"]["model"] == "reaction",
              do: gettext("Simulation: balance a chemical equation (computed by the server)."),
              else: gettext("Simulation: launch a planet on a stable orbit (computed by the server).")}
          </p>
          <p>{@lesson["content"]["goal_text"]}</p>
        <% "minigame" -> %>
          <p>{@lesson["content"]["prompt"]}</p>
          <p class="text-sm text-muted">
            {if @lesson["content"]["game"] == "constellation",
              do:
                ngettext(
                  "Constellation: %{count} star to link in order.",
                  "Constellation: %{count} stars to link in order.",
                  length(@lesson["content"]["stars"] || [])
                ),
              else:
                ngettext(
                  "Sequence: %{count} item, shuffled for each learner.",
                  "Sequence: %{count} items, shuffled for each learner.",
                  length(@lesson["content"]["items"] || [])
                )}
          </p>
        <% _ -> %>
      <% end %>
    </article>
    """
  end
end
