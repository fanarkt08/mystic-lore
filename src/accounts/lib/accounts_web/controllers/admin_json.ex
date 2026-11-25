defmodule MlAccountsWeb.AdminJSON do
  @moduledoc "Formes JSON des routes du staff."
  alias MlAccounts.{Sanction, Sanctions, Staff, User}

  @doc "Membre vu du staff : e-mail complet pour un admin, masqué (`l•••@domaine`) pour un modérateur."
  def member(%User{} = user, viewer) do
    %{
      id: user.id,
      username: user.username,
      display_name: user.display_name,
      avatar: MlAccounts.Avatars.public(user),
      email: if(Staff.admin?(viewer), do: user.email, else: Staff.mask_email(user.email)),
      email_masked: not Staff.admin?(viewer),
      role: user.role,
      confirmed: not is_nil(user.confirmed_at),
      restricted_until: Sanctions.restricted_until(user),
      deletion_scheduled_at: user.deletion_scheduled_at,
      inserted_at: user.inserted_at
    }
  end

  def member_detail(%User{} = user, viewer, sanctions) do
    people = Staff.people(Enum.flat_map(sanctions, &sanction_people/1))

    Map.merge(member(user, viewer), %{
      bio: user.bio,
      two_factor: not is_nil(user.totp_enabled_at),
      sanctions: Enum.map(sanctions, &sanction(&1, people))
    })
  end

  defp sanction_people(s),
    do: [s.issued_by, s.lifted_by | Enum.map(s.appeals, & &1.decided_by)]

  @doc "Sanction vue du staff (auteur, levée, appels)."
  def sanction(%Sanction{} = s, people) do
    %{
      id: s.id,
      user_id: s.user_id,
      kind: s.kind,
      reason: s.reason,
      status: Sanction.status(s),
      ends_at: s.ends_at,
      ref: s.ref,
      issued_by: person(people, s.issued_by),
      inserted_at: s.inserted_at,
      lifted_at: s.lifted_at,
      lifted_by: person(people, s.lifted_by),
      lift_reason: s.lift_reason,
      appeals: if(is_list(s.appeals), do: Enum.map(s.appeals, &appeal(&1, people)), else: [])
    }
  end

  @doc "Sanction vue par le membre : ni l'auteur, ni la clé du service ; dernier appel et droit d'appel."
  def own_sanction(%Sanction{} = s) do
    %{
      id: s.id,
      kind: s.kind,
      reason: s.reason,
      status: Sanction.status(s),
      ends_at: s.ends_at,
      inserted_at: s.inserted_at,
      lifted_at: s.lifted_at,
      lift_reason: s.lift_reason,
      appealable: Sanctions.appealable?(s),
      appeal:
        case s.appeals do
          [latest | _] ->
            %{
              id: latest.id,
              status: latest.status,
              body: latest.body,
              decision_reason: latest.decision_reason,
              decided_at: latest.decided_at,
              inserted_at: latest.inserted_at
            }

          _ ->
            nil
        end
    }
  end

  def appeal(appeal, people) do
    %{
      id: appeal.id,
      sanction_id: appeal.sanction_id,
      status: appeal.status,
      body: appeal.body,
      decision_reason: appeal.decision_reason,
      decided_at: appeal.decided_at,
      decided_by: person(people, appeal.decided_by),
      inserted_at: appeal.inserted_at
    }
  end

  @doc "Appel de la file du staff : le membre (public), la sanction et son auteur."
  def queued_appeal(appeal, people) do
    sanction = %{appeal.sanction | appeals: nil}

    appeal
    |> appeal(people)
    |> Map.merge(%{
      member: %{
        id: appeal.user.id,
        username: appeal.user.username,
        display_name: appeal.user.display_name
      },
      sanction: sanction(sanction, people)
    })
  end

  def incident(incident, people) do
    %{
      id: incident.id,
      title: incident.title,
      severity: incident.severity,
      status: incident.status,
      summary: incident.summary,
      created_by: person(people, incident.created_by),
      resolved_by: person(people, incident.resolved_by),
      resolved_at: incident.resolved_at,
      inserted_at: incident.inserted_at,
      updated_at: incident.updated_at
    }
  end

  def incident_detail(incident, people) do
    Map.put(
      incident(incident, people),
      :updates,
      for u <- incident.updates do
        %{
          id: u.id,
          body: u.body,
          status: u.status,
          severity: u.severity,
          author: person(people, u.author_id),
          inserted_at: u.inserted_at
        }
      end
    )
  end

  def audit_entry(e) do
    %{
      id: e.id,
      service: e.service,
      actor: e.actor || %{id: e.actor_id, username: nil, display_name: nil},
      action: e.action,
      target_type: e.target_type,
      target_id: e.target_id,
      reason: e.reason,
      metadata: e.metadata,
      inserted_at: e.inserted_at
    }
  end

  defp person(_people, nil), do: nil
  defp person(people, id), do: people[id] || %{id: id, username: nil, display_name: nil}
end
