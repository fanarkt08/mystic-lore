defmodule MlSocialWeb.ModerationController do
  @moduledoc """
  Signalements pour le staff : file, preuve sur motif, résolution et indicateurs.
  Aucune route du staff ne lit une conversation.
  """
  use MlSocialWeb, :controller
  alias MlSocial.{Accounts, Moderation}
  alias MlSocialWeb.FallbackController

  action_fallback FallbackController
  plug :require_staff

  def index(conn, params) do
    page = Moderation.list(params)
    users = Accounts.users(Enum.flat_map(page.entries, &people/1))
    json(conn, %{page | entries: Enum.map(page.entries, &report(&1, users))})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, report} <- Moderation.get(id),
         do: json(conn, %{report: report(report, Accounts.users(people(report)))})
  end

  def evidence(conn, %{"id" => id} = params) do
    with {:ok, evidence} <- Moderation.evidence(conn.assigns.user_id, id, params) do
      sender = Accounts.users([evidence.sender_id])[evidence.sender_id]
      json(conn, %{evidence: Map.put(evidence, :sender, sender)})
    end
  end

  # pièce jointe du message signalé : octets renvoyés après l'entrée d'audit (motif de 10 caractères au moins)
  def attachment(conn, %{"id" => id} = params) do
    with {:ok, attachment, data} <- Moderation.attachment(conn.assigns.user_id, id, params),
         do: MlSocialWeb.AttachmentController.send_file_bytes(conn, attachment, data)
  end

  def resolve(conn, %{"id" => id} = params) do
    with {:ok, report} <- Moderation.resolve(conn.assigns.user_id, id, params),
         do: json(conn, %{report: report(report, Accounts.users(people(report)))})
  end

  def stats(conn, _params), do: json(conn, %{stats: Moderation.stats()})

  defp people(r), do: Enum.reject([r.reporter_id, reported(r)], &is_nil/1)

  defp reported(%{target_type: "message"} = r), do: r.message_sender_id
  defp reported(r), do: r.target_id

  # Jamais le texte du message signalé : seulement son identifiant, sa date et son état actuel.
  defp report(r, users) do
    %{
      id: r.id,
      target_type: r.target_type,
      target_id: r.target_id,
      reason: r.reason,
      details: r.details,
      context:
        if(is_binary(r.details) and String.starts_with?(r.details, "Multiplayer lobby "),
          do: "multiplayer"
        ),
      status: r.status,
      reporter: users[r.reporter_id],
      reported_user: users[reported(r)],
      message:
        if(r.target_type == "message",
          do: %{id: r.target_id, sent_at: r.message_sent_at, removed: r.message_removed == true}
        ),
      resolution:
        if(r.status == "resolved",
          do: %{
            action: r.resolution,
            reason: r.resolution_reason,
            moderator_id: r.resolved_by,
            sanction_id: r.sanction_id,
            resolved_at: r.resolved_at
          }
        ),
      inserted_at: r.inserted_at
    }
  end

  defp require_staff(conn, _opts) do
    case Accounts.require_staff(conn.assigns.user_id) do
      :ok -> conn
      error -> conn |> FallbackController.call(error) |> halt()
    end
  end
end
