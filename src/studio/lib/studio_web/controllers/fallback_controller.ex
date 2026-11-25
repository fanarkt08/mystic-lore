defmodule MlStudioWeb.FallbackController do
  @moduledoc "Errors of the contexts in the contract format: `{\"error\": code}` (+ details)."
  use Phoenix.Controller, formats: [:json]
  import Plug.Conn
  alias MlStudio.View

  @statuses %{
    not_found: 404,
    user_not_found: 404,
    forbidden: 403,
    blocked: 403,
    own_project: 403,
    vip_required: 402,
    locked: 409,
    already_collaborator: 409,
    too_many_modules: 409,
    too_many_lessons: 409,
    too_many_images: 409,
    too_many_media: 409,
    too_many_captions: 409,
    too_many_collaborators: 409,
    too_many_generations: 409,
    not_draft: 409,
    not_submitted: 409,
    not_approved: 409,
    not_cancellable: 409,
    not_retryable: 409,
    not_applicable: 409,
    already_applied: 409,
    target_missing: 409,
    reservation_closed: 409,
    self: 422,
    attestations_required: 422,
    accounts_unavailable: 503,
    audit_unavailable: 503,
    social_unavailable: 503,
    billing_unavailable: 503,
    credits_unavailable: 503
  }

  @messages %{
    image_generation_unavailable:
      "image generation is not available with the configured provider",
    ai_not_configured:
      "the AI provider is not configured on this server (ANTHROPIC_API_KEY is missing)"
  }

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    invalid(conn, errors)
  end

  def call(conn, {:error, {:invalid, errors}}), do: invalid(conn, errors)

  def call(conn, {:error, {:conflict, current}}),
    do: conn |> put_status(409) |> json(%{error: "conflict", current: current(current)})

  def call(conn, {:error, {:insufficient_credits, balance}}),
    do: conn |> put_status(402) |> json(%{error: "insufficient_credits", balance: balance})

  def call(conn, {:error, {:cost_mismatch, cost}}),
    do: conn |> put_status(409) |> json(%{error: "cost_mismatch", cost: cost})

  def call(conn, {:error, {:checks_failed, checks}}),
    do: conn |> put_status(422) |> json(%{error: "checks_failed", checks: checks})

  def call(conn, {:error, code})
      when code in [:image_generation_unavailable, :ai_not_configured] do
    status = if code == :ai_not_configured, do: 503, else: 422
    conn |> put_status(status) |> json(%{error: code, message: @messages[code]})
  end

  def call(conn, {:error, code}) when is_map_key(@statuses, code),
    do: conn |> put_status(@statuses[code]) |> json(%{error: code})

  defp invalid(conn, errors),
    do: conn |> put_status(422) |> json(%{error: "invalid", errors: errors})

  defp current(%MlStudio.Projects.Project{} = p), do: View.brief(p)
  defp current(%MlStudio.Projects.CourseModule{} = m), do: View.module(m)
  defp current(%MlStudio.Projects.Lesson{} = l), do: View.lesson(l)
end
