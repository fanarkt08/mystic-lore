defmodule MlSocial.Groups do
  @moduledoc """
  Conversations de groupe de 3 à 20 membres, où chacun doit être ami de celui qui l'ajoute.
  Les écritures verrouillent la ligne du groupe pour que la limite de membres reste exacte.
  """
  import Ecto.Query

  alias MlSocial.{
    Attachments,
    Chat,
    Conversation,
    Delivery,
    Friends,
    Member,
    Message,
    Repo,
    Settings
  }

  @max_members 20
  @name_max 60
  # caractères de contrôle et contrôles bidirectionnels (usurpation d'affichage)
  @forbidden ~r/[\p{Cc}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u

  def max_members, do: @max_members

  def create(me, params) do
    with {:ok, name} <- name(params["name"]),
         {:ok, ids} <- invitees(me, params["member_ids"]),
         {:ok, {conversation, created}} <- Repo.transact(fn -> create_locked(me, name, ids) end) do
      Delivery.new_message(conversation, created)
      Delivery.changed(conversation.id)
      for id <- ids, do: MlSocial.Notify.group_added(conversation, id, me)
      Chat.get(me, conversation.id)
    end
  end

  defp create_locked(me, name, ids) do
    with :ok <- check_adds(me, ids) do
      now = DateTime.utc_now()
      conversation = Repo.insert!(%Conversation{kind: "group", name: name, owner_id: me})

      # ancienneté : le créateur, puis les membres dans l'ordre donné ; toutes les arrivées précèdent `now`, donc
      # le message système de création, que chacun lit (l'historique commence à l'arrivée, `MlSocial.Chat`)
      rows =
        for {id, i} <- Enum.with_index([me | ids]),
            do: %{
              conversation_id: conversation.id,
              user_id: id,
              joined_at: DateTime.add(now, i - length(ids) - 1, :microsecond)
            }

      Repo.insert_all(Member, rows)
      created = Repo.insert!(Message.system(conversation.id, me, "created", %{"name" => name}))
      {:ok, {conversation, created}}
    end
  end

  def rename(me, conversation_id, params) do
    with {:ok, name} <- name(params["name"]) do
      change(me, conversation_id, fn conversation ->
        with :ok <- owner(conversation, me) do
          if conversation.name == name do
            {:ok, nil}
          else
            Repo.update!(Ecto.Changeset.change(conversation, name: name))
            {:ok, Message.system(conversation.id, me, "renamed", %{"name" => name})}
          end
        end
      end)
    end
  end

  def add_member(me, conversation_id, user_id) do
    with {:ok, target} <- Friends.other_user(me, user_id),
         {:ok, summary} <- add_locked(me, conversation_id, target) do
      MlSocial.Notify.group_added(summary.conversation, target, me)
      {:ok, summary}
    end
  end

  defp add_locked(me, conversation_id, target) do
    change(me, conversation_id, fn conversation ->
      with :ok <- owner(conversation, me),
           :ok <- absent(conversation, target),
           :ok <- room(conversation),
           :ok <- check_adds(me, [target]) do
        Repo.insert!(%Member{
          conversation_id: conversation.id,
          user_id: target,
          joined_at: DateTime.utc_now()
        })

        {:ok, Message.system(conversation.id, me, "member_added", %{"target_id" => target})}
      end
    end)
  end

  def remove_member(me, conversation_id, user_id) do
    with {:ok, target} <- cast(user_id),
         {:ok, summary} <- remove_locked(me, conversation_id, target) do
      MlSocial.Notify.left_group(target, summary.conversation.id)
      {:ok, summary}
    end
  end

  defp remove_locked(me, conversation_id, target) do
    change(
      me,
      conversation_id,
      fn conversation ->
        cond do
          conversation.owner_id != me ->
            {:error, :not_owner}

          target == me ->
            {:error, :self}

          delete_member(conversation, target) == 0 ->
            {:error, :not_found}

          true ->
            {:ok, Message.system(conversation.id, me, "member_removed", %{"target_id" => target})}
        end
      end,
      [target]
    )
  end

  @doc "Fait quitter le groupe à `me` et transfère la propriété au membre le plus ancien."
  def leave(me, conversation_id) do
    result =
      Repo.transact(fn ->
        with {:ok, conversation} <- locked_group(me, conversation_id) do
          delete_member(conversation, me)
          leave_locked(conversation, me)
        end
      end)

    case result do
      {:ok, {:deleted, conversation, keys}} ->
        Enum.each(keys, &Attachments.delete_file/1)
        Delivery.changed(conversation.id, [me])
        MlSocial.Notify.left_group(me, conversation.id)

      {:ok, {:left, conversation, left}} ->
        Delivery.new_message(conversation, left)
        Delivery.changed(conversation.id, [me])
        MlSocial.Notify.left_group(me, conversation.id)

      error ->
        error
    end
  end

  defp leave_locked(conversation, me) do
    remaining =
      Repo.all(
        from m in Member,
          where: m.conversation_id == ^conversation.id,
          order_by: [m.joined_at, m.user_id],
          select: m.user_id
      )

    case remaining do
      [] ->
        keys = Attachments.keys(conversation.id)
        Repo.delete!(conversation)
        {:ok, {:deleted, conversation, keys}}

      [oldest | _] ->
        new_owner = if conversation.owner_id == me, do: oldest

        conversation =
          if new_owner,
            do: Repo.update!(Ecto.Changeset.change(conversation, owner_id: new_owner)),
            else: conversation

        left =
          Repo.insert!(
            Message.system(conversation.id, me, "member_left", %{"target_id" => new_owner})
          )

        {:ok, {:left, conversation, left}}
    end
  end

  # Applique `fun` au groupe verrouillé ; le message système éventuel est inséré, livré, puis le groupe renvoyé.
  defp change(me, conversation_id, fun, also \\ []) do
    result =
      Repo.transact(fn ->
        with {:ok, conversation} <- locked_group(me, conversation_id),
             {:ok, system} <- fun.(conversation) do
          {:ok, {conversation, system && Repo.insert!(system)}}
        end
      end)

    with {:ok, {conversation, system}} <- result do
      if system do
        Delivery.new_message(conversation, system)
        Delivery.changed(conversation.id, also)
      end

      Chat.get(me, conversation.id)
    end
  end

  defp locked_group(me, conversation_id) do
    with {:ok, id} <- cast(conversation_id),
         %Conversation{kind: "group"} = conversation <-
           Repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR UPDATE"),
         true <-
           Repo.exists?(from m in Member, where: m.conversation_id == ^id and m.user_id == ^me) do
      {:ok, conversation}
    else
      _ -> {:error, :not_found}
    end
  end

  defp owner(%Conversation{owner_id: me}, me), do: :ok
  defp owner(_conversation, _me), do: {:error, :not_owner}

  defp absent(conversation, user_id) do
    if Repo.exists?(member(conversation, user_id)), do: {:error, :already_member}, else: :ok
  end

  defp room(conversation) do
    count =
      Repo.aggregate(from(m in Member, where: m.conversation_id == ^conversation.id), :count)

    if count < @max_members, do: :ok, else: {:error, :group_full}
  end

  defp delete_member(conversation, user_id),
    do: conversation |> member(user_id) |> Repo.delete_all() |> elem(0)

  defp member(conversation, user_id),
    do: from(m in Member, where: m.conversation_id == ^conversation.id and m.user_id == ^user_id)

  # Sous verrou partagé de chaque paire, dans l'ordre des identifiants : un blocage ou un retrait d'ami simultané
  # attend la fin de l'ajout (et l'ajout voit son résultat s'il est arrivé avant).
  defp check_adds(me, ids) do
    Enum.reduce_while(Enum.sort(ids), :ok, fn id, :ok ->
      Friends.lock_pair(me, id, :shared)

      case Settings.can_contact(me, id, "group_add") do
        :ok -> {:cont, :ok}
        {:error, code} -> {:halt, {:error, {:refused, code, id}}}
      end
    end)
  end

  defp name(name) when is_binary(name) do
    name = String.trim(name)

    cond do
      name == "" -> invalid(:name, "can't be blank")
      String.length(name) > @name_max -> invalid(:name, "should be at most 60 character(s)")
      Regex.match?(@forbidden, name) -> invalid(:name, "must not contain control characters")
      true -> {:ok, name}
    end
  end

  defp name(_name), do: invalid(:name, "can't be blank")

  # Membres à ajouter à la création (le créateur en plus) : 2 à 19 identifiants distincts.
  defp invitees(me, ids) when is_list(ids) do
    casted = Enum.map(ids, &Ecto.UUID.cast/1)

    cond do
      Enum.any?(casted, &(&1 == :error)) ->
        invalid(:member_ids, "is invalid")

      true ->
        ids = casted |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> List.delete(me)

        if length(ids) in 2..(@max_members - 1),
          do: {:ok, ids},
          else: invalid(:member_ids, "must list 2 to 19 friends")
    end
  end

  defp invitees(_me, _ids), do: invalid(:member_ids, "must list 2 to 19 friends")

  defp invalid(field, message), do: {:error, {:invalid, %{field => [message]}}}

  defp cast(id) do
    with :error <- Ecto.UUID.cast(id), do: {:error, :not_found}
  end
end
