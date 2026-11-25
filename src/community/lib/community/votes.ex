defmodule MlCommunity.Votes do
  @moduledoc "Votes « utile », un par membre et par cible, jamais sur son propre contenu."
  import Ecto.Query
  alias MlCommunity.{Discussion, Reply, Repo, Viewer, Vote}

  @doc "`{:ok, %{voted: bool, helpful_count: int}}` ou `{:error, :own_content | :forbidden}`."
  def set(%Viewer{id: me}, %schema{} = target, on?)
      when schema in [Discussion, Reply] and is_boolean(on?) do
    cond do
      target.author_id == me -> {:error, :own_content}
      target.status != "visible" -> {:error, :forbidden}
      true -> Repo.transact(fn -> {:ok, write(me, schema, target.id, on?)} end)
    end
  end

  defp write(me, schema, id, on?) do
    type = if schema == Discussion, do: "discussion", else: "reply"

    vote =
      from v in Vote, where: v.user_id == ^me and v.target_type == ^type and v.target_id == ^id

    {changed, _} =
      if on? do
        row = %{user_id: me, target_type: type, target_id: id, inserted_at: DateTime.utc_now()}
        Repo.insert_all(Vote, [row], on_conflict: :nothing)
      else
        Repo.delete_all(vote)
      end

    counter = from t in schema, where: t.id == ^id, select: t.helpful_count

    count =
      if changed == 0 do
        Repo.one!(counter)
      else
        {1, [count]} = Repo.update_all(counter, inc: [helpful_count: if(on?, do: 1, else: -1)])
        count
      end

    %{voted: on?, helpful_count: count}
  end
end
