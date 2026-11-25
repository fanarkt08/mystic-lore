defmodule MlNotifications.Accounts do
  @moduledoc """
  Identités des acteurs lues chez accounts, en une requête par réponse et sans relance. Si accounts est
  injoignable, les acteurs valent `nil` (web affiche « a member ») et la liste reste servie.
  """

  def identities(ids) do
    ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.chunk_every(100)
    |> Enum.reduce(%{}, fn chunk, acc ->
      case MlShared.Client.get(:accounts, "/api/users",
             params: [ids: Enum.join(chunk, ",")],
             retry: false
           ) do
        {:ok, %{"users" => users}} when is_list(users) ->
          Enum.reduce(users, acc, fn
            %{"id" => id} = user, acc ->
              Map.put(acc, id, Map.take(user, ~w(id username display_name avatar)))

            _other, acc ->
              acc
          end)

        _unavailable ->
          acc
      end
    end)
  end
end
