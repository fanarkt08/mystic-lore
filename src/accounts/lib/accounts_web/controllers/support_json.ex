defmodule MlAccountsWeb.SupportJSON do
  @moduledoc """
  Formes JSON des demandes de support. Le demandeur ne voit jamais la note interne ni l'identité du staff.
  """
  alias MlAccounts.{Staff, SupportRequest}

  def created(%SupportRequest{} = r, acknowledgement) do
    %{
      request: %{
        id: r.id,
        reference: r.reference,
        topic: r.topic,
        status: r.status,
        inserted_at: r.inserted_at
      },
      acknowledgement: to_string(acknowledgement)
    }
  end

  @doc "Demande vue par le membre qui l'a envoyée : réponses signées « l'équipe », jamais la note interne."
  def own(%SupportRequest{} = r) do
    %{
      id: r.id,
      reference: r.reference,
      topic: r.topic,
      message: r.message,
      status: r.status,
      inserted_at: r.inserted_at,
      answered_at: r.answered_at,
      closed_at: r.closed_at,
      replies: Enum.map(r.replies, &%{id: &1.id, body: &1.body, inserted_at: &1.inserted_at})
    }
  end

  @doc "Ligne de la liste du staff (sans le texte de la demande)."
  def entry(%SupportRequest{} = r, viewer, users, replies) do
    %{
      id: r.id,
      reference: r.reference,
      topic: r.topic,
      status: r.status,
      locale: r.locale,
      requester: requester(r, viewer, users),
      replies: replies,
      inserted_at: r.inserted_at,
      updated_at: r.updated_at,
      answered_at: r.answered_at,
      closed_at: r.closed_at
    }
  end

  @doc "Détail pour le staff : texte de la demande, note interne, réponses (auteur, remise de l'e-mail)."
  def detail(%SupportRequest{} = r, viewer, users, people) do
    r
    |> entry(viewer, users, length(r.replies))
    |> Map.merge(%{
      message: r.message,
      internal_note: r.internal_note,
      replies:
        Enum.map(r.replies, fn reply ->
          %{
            id: reply.id,
            body: reply.body,
            author: people[reply.author_id],
            email_status: reply.email_status,
            inserted_at: reply.inserted_at
          }
        end)
    })
  end

  defp requester(%SupportRequest{user_id: nil, email: email}, viewer, _users),
    do: %{kind: "visitor", member: nil} |> Map.merge(address(email, viewer))

  defp requester(%SupportRequest{user_id: user_id}, viewer, users) do
    case users[user_id] do
      nil ->
        %{kind: "member", member: nil, email: nil, email_masked: true}

      user ->
        %{
          kind: "member",
          member: %{id: user.id, username: user.username, display_name: user.display_name}
        }
        |> Map.merge(address(user.email, viewer))
    end
  end

  defp address(email, viewer) do
    if Staff.admin?(viewer),
      do: %{email: email, email_masked: false},
      else: %{email: Staff.mask_email(email), email_masked: true}
  end
end
