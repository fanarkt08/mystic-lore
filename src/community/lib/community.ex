defmodule MlCommunity do
  @moduledoc """
  Service communautaire (forum) : lecture et visibilité (`MlCommunity.Forum`), publications (`MlCommunity.Posts`),
  votes, signalements et modération. La base ne stocke que des UUID de membres : les profils viennent d'accounts.
  """
  import Ecto.Changeset
  import Ecto.Query
  alias MlCommunity.Repo

  @doc "Renvoie une page de `query` au format du contrat ; une page invalide vaut 1."
  def paginate(query, page, per_page, finish) do
    page = page_number(page)
    total = Repo.aggregate(query, :count)

    entries =
      query |> limit(^per_page) |> offset(^((page - 1) * per_page)) |> finish.() |> Repo.all()

    %{
      entries: entries,
      page: page,
      total: total,
      total_pages: max(div(total + per_page - 1, per_page), 1)
    }
  end

  defp page_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> min(n, 10_000)
      _ -> 1
    end
  end

  defp page_number(_), do: 1

  @doc "PostgreSQL refuse l'octet NUL dans un texte : on le rejette en 422 plutôt qu'en 500."
  def validate_no_nul(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      validate_change(changeset, field, fn _, value ->
        if String.contains?(value, <<0>>), do: [{field, "is invalid"}], else: []
      end)
    end)
  end

  @doc "Texte libre facultatif : espaces de bord retirés, `nil` si vide ou absent."
  def trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  def trimmed(_), do: nil
end
