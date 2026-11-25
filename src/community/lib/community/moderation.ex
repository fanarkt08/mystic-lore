defmodule MlCommunity.Moderation do
  @moduledoc """
  Actions du staff sur les discussions et les réponses, journalisées et auditées dans la même transaction.
  """
  import Ecto.Changeset
  import Ecto.Query
  alias MlCommunity.{Accounts, Category, Discussion, ModerationEntry, Posts, Reply, Repo}

  @actions %{
    discussion: ~w(hide remove restore lock unlock pin unpin move),
    reply: ~w(hide remove restore)
  }

  @doc "`:ok` ou `{:error, :not_found | :conflict | {:invalid, errors}}`."
  def act(staff_id, type, id, params) when type in [:discussion, :reply] do
    action = params["action"]
    reason = MlCommunity.trimmed(params["reason"])

    with :ok <- validate(type, action, reason),
         {:ok, id} <- cast_id(id),
         {:ok, _entry} <-
           Repo.transact(fn ->
             with {:ok, target} <- lock_target(type, id),
                  {:ok, changes, metadata} <- changes(target, action, reason, params) do
               target |> change(changes) |> Repo.update!()

               if type == :reply and action in ~w(hide remove),
                 do: Posts.unset_solution(target.id)

               log(staff_id, action, Atom.to_string(type), target.id, reason, metadata)
             end
           end),
         do: :ok
  end

  defp validate(type, action, reason) do
    cond do
      action not in @actions[type] ->
        {:error, {:invalid, %{action: ["is invalid"]}}}

      action in ~w(hide remove) and is_nil(reason) ->
        {:error, {:invalid, %{reason: ["can't be blank"]}}}

      reason && String.length(reason) > 500 ->
        {:error, {:invalid, %{reason: ["should be at most 500 character(s)"]}}}

      true ->
        :ok
    end
  end

  defp cast_id(id) do
    with :error <- Ecto.UUID.cast(id), do: {:error, :not_found}
  end

  defp lock_target(type, id) do
    schema = if type == :discussion, do: Discussion, else: Reply

    case Repo.one(from x in schema, where: x.id == ^id, lock: "FOR UPDATE") do
      nil -> {:error, :not_found}
      target -> {:ok, target}
    end
  end

  defp changes(%{status: "deleted"}, _action, _reason, _params), do: {:error, :conflict}

  defp changes(target, action, reason, _params) when action in ~w(hide remove) do
    status = if action == "hide", do: "hidden", else: "removed"
    {:ok, [status: status, moderation_reason: reason], %{"from" => target.status, "to" => status}}
  end

  defp changes(%{status: status}, "restore", _reason, _params) when status in ~w(hidden removed),
    do: {:ok, [status: "visible", moderation_reason: nil], %{"from" => status, "to" => "visible"}}

  defp changes(_target, "restore", _reason, _params), do: {:error, :conflict}
  defp changes(_target, "lock", _reason, _params), do: {:ok, [locked: true], %{}}
  defp changes(_target, "unlock", _reason, _params), do: {:ok, [locked: false], %{}}
  defp changes(_target, "pin", _reason, _params), do: {:ok, [pinned: true], %{}}
  defp changes(_target, "unpin", _reason, _params), do: {:ok, [pinned: false], %{}}

  defp changes(target, "move", _reason, params) do
    case is_binary(params["category"]) && Repo.get(Category, params["category"]) do
      %Category{slug: slug} ->
        {:ok, [category: slug], %{"from" => target.category, "to" => slug}}

      _ ->
        {:error, {:invalid, %{category: ["is invalid"]}}}
    end
  end

  @doc """
  Inscrit une action dans le journal de modération local et dans le journal d'audit d'accounts
  (`community.<cible>.<action>`), dans la transaction de l'action : `{:error, :audit_unavailable}` l'annule.
  """
  def log(staff_id, action, target_type, target_id, reason, metadata \\ %{}) do
    entry =
      Repo.insert!(%ModerationEntry{
        moderator_id: staff_id,
        action: action,
        target_type: target_type,
        target_id: target_id,
        reason: reason,
        metadata: metadata
      })

    verb = if action == "resolve_report", do: "resolved", else: action

    with :ok <-
           Accounts.audit(
             staff_id,
             "community.#{target_type}.#{verb}",
             target_type,
             target_id,
             reason,
             metadata
           ),
         do: {:ok, entry}
  end
end
