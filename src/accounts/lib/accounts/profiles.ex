defmodule MlAccounts.Profiles do
  @moduledoc """
  Filtre le profil d'un membre selon le lecteur, pour la vraie page comme pour l'aperçu.
  Un blocage ou un service social injoignable comptent comme « pas ami ».
  """
  alias MlAccounts.{Avatars, User}

  @readers ~w(visitor member friend)a

  @doc "Catégories de l'aperçu (`self` n'en est pas une : le membre voit tout)."
  def preview_readers, do: Enum.map(@readers, &Atom.to_string/1)

  @doc "Ce que reçoit le lecteur `reader_id` (UUID du jeton interne, ou nil)."
  def for_reader(%User{} = owner, reader_id), do: view(owner, reader(owner, reader_id))

  @doc "Profil filtré pour une catégorie de lecteur."
  def view(%User{} = owner, reader) when reader in [:self | @readers] do
    shared? = shared?(owner.profile_visibility, reader)

    %{
      id: owner.id,
      username: owner.username,
      display_name: owner.display_name,
      avatar: Avatars.public(owner),
      cover: owner.cover,
      visibility: owner.profile_visibility,
      details:
        if(shared?,
          do: %{bio: owner.bio, pronouns: owner.pronouns, interests: owner.interests},
          else: nil
        ),
      academy_record: shared?
    }
  end

  defp shared?("public", _reader), do: true
  defp shared?("members", reader), do: reader != :visitor
  defp shared?("friends", reader), do: reader in [:friend, :self]
  defp shared?("private", reader), do: reader == :self

  @doc "Catégorie du lecteur."
  def reader(%User{}, nil), do: :visitor
  def reader(%User{id: id}, id), do: :self

  def reader(%User{} = owner, reader_id) do
    case MlAccounts.get_user(reader_id) do
      %User{} = reader ->
        cond do
          MlAccounts.Privacy.deleting?(reader) -> :visitor
          owner.profile_visibility == "friends" and friends?(owner.id, reader.id) -> :friend
          true -> :member
        end

      nil ->
        :visitor
    end
  end

  defp friends?(a, b) do
    case MlShared.Client.get(:social, "/api/internal/relationship", params: [a: a, b: b]) do
      {:ok, %{"friends" => true, "blocked" => false}} -> true
      _ -> false
    end
  end
end
