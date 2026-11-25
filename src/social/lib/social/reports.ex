defmodule MlSocial.Reports do
  @moduledoc """
  Signalements de membres et de messages ; le texte d'un message signalé est copié dans le signalement.
  """
  import Ecto.Changeset
  import Ecto.Query
  alias MlSocial.{Conversation, Member, Message, Repo, Report}

  def create(me, attrs) do
    %Report{reporter_id: me}
    |> Report.changeset(attrs)
    |> check_target(me)
    |> Repo.insert()
  end

  defp check_target(%{valid?: true} = changeset, me) do
    target = get_field(changeset, :target_id)

    case get_field(changeset, :target_type) do
      "user" when target == me ->
        add_error(changeset, :target_id, "cannot be yourself")

      "user" ->
        changeset

      "message" ->
        case visible_message(me, target) do
          %Message{kind: "system"} ->
            add_error(changeset, :target_id, "is invalid")

          %Message{sender_id: ^me} ->
            add_error(changeset, :target_id, "cannot be your own message")

          %Message{} = m ->
            change(changeset,
              message_body: m.body,
              message_sender_id: m.sender_id,
              message_sent_at: m.inserted_at,
              message_attachment_id: m.attachment && m.attachment.id
            )

          # inexistant ou hors de vos conversations : même réponse (pas de divulgation)
          nil ->
            add_error(changeset, :target_id, "is invalid")
        end
    end
  end

  defp check_target(changeset, _me), do: changeset

  # Un message que `me` peut lire : membre actuel et, dans un groupe, écrit depuis son arrivée (`MlSocial.Chat`).
  defp visible_message(me, id) do
    Repo.one(
      from m in Message,
        join: mb in Member,
        on: mb.conversation_id == m.conversation_id and mb.user_id == ^me,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where: m.id == ^id,
        where: c.kind != "group" or m.inserted_at >= mb.joined_at,
        preload: :attachment
    )
  end
end
