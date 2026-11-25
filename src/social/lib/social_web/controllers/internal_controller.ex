defmodule MlSocialWeb.InternalController do
  @moduledoc "Relations, blocages, permissions de contact et sourdines, pour les autres services."
  use MlSocialWeb, :controller
  alias MlSocial.{Chat, Friends, Settings}

  @contact_errors %{
    query: ["from and to must be UUIDs, kind friend_request, group_add or lobby_invite"]
  }

  def relationship(conn, %{"a" => a, "b" => b}) do
    with {:ok, a} <- Ecto.UUID.cast(a), {:ok, b} <- Ecto.UUID.cast(b) do
      json(conn, %{
        friends: a != b and Friends.friends?(a, b),
        blocked: a != b and Friends.blocked?(a, b)
      })
    else
      _ -> invalid(conn)
    end
  end

  def relationship(conn, _), do: invalid(conn)

  def blocks(conn, %{"user_id" => user_id}) do
    case Ecto.UUID.cast(user_id) do
      {:ok, id} -> json(conn, %{user_ids: Friends.blocked_either_ids(id)})
      :error -> invalid(conn)
    end
  end

  def can_contact(conn, %{"from" => from, "to" => to, "kind" => kind}) do
    with {:ok, from} <- Ecto.UUID.cast(from),
         {:ok, to} <- Ecto.UUID.cast(to),
         true <- kind in Settings.kinds() do
      case Settings.can_contact(from, to, kind) do
        :ok -> json(conn, %{allowed: true})
        {:error, code} -> conn |> put_status(403) |> json(%{error: code})
      end
    else
      _ -> invalid(conn, @contact_errors)
    end
  end

  def can_contact(conn, _), do: invalid(conn, @contact_errors)

  def mutes(conn, %{"user_id" => user_id}) do
    case Ecto.UUID.cast(user_id) do
      {:ok, id} ->
        mutes =
          for {cid, until} <- Chat.mutes(id), do: %{conversation_id: cid, muted_until: until}

        json(conn, %{mutes: mutes})

      :error ->
        invalid(conn)
    end
  end

  defp invalid(conn, errors \\ %{user_id: ["is invalid"]}),
    do: conn |> put_status(422) |> json(%{error: "invalid", errors: errors})
end
