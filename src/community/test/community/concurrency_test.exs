defmodule MlCommunity.ConcurrencyTest do
  @moduledoc """
  Courses réelles : chaque opération tourne hors sandbox, sur sa propre connexion et dans sa propre
  transaction validée. Les membres sont des UUID aléatoires ; leurs lignes sont supprimées à la fin.
  """
  use ExUnit.Case, async: false
  import Ecto.Query
  import MlCommunity.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias MlCommunity.{Discussion, Posts, Reply, Repo, Vote, Votes}

  setup do
    stub_services()
    author = uuid()

    on_exit(fn ->
      unboxed(fn ->
        ids = Repo.all(from d in Discussion, where: d.author_id == ^author, select: d.id)
        Repo.delete_all(from v in Vote, where: v.target_id in ^ids)
        Repo.delete_all(from d in Discussion, where: d.id in ^ids)
      end)
    end)

    {:ok, author: author, discussion: unboxed(fn -> discussion!(author) end)}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp concurrently(funs) do
    funs
    |> Task.async_stream(&unboxed/1, max_concurrency: 20, timeout: 30_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp counter(d), do: unboxed(fn -> Repo.get!(Discussion, d.id).helpful_count end)
  defp rows(d), do: unboxed(fn -> Repo.aggregate(where(Vote, target_id: ^d.id), :count) end)

  test "the same member voting 20 times at once: one row, counter at 1", %{discussion: d} do
    voter = uuid()
    results = concurrently(for _ <- 1..20, do: fn -> Votes.set(viewer(voter), d, true) end)

    assert Enum.all?(results, &match?({:ok, %{voted: true}}, &1))
    assert rows(d) == 1
    assert counter(d) == 1
  end

  test "20 members voting at once, then mixed vote / unvote: counter always equals the rows", %{
    discussion: d
  } do
    voters = for _ <- 1..20, do: uuid()
    concurrently(for v <- voters, do: fn -> Votes.set(viewer(v), d, true) end)
    assert rows(d) == 20 and counter(d) == 20

    concurrently(
      for {v, i} <- Enum.with_index(voters),
          _ <- 1..3,
          do: fn -> Votes.set(viewer(v), d, rem(i, 2) == 0) end
    )

    assert rows(d) == 10
    assert counter(d) == 10
  end

  test "rate limit under concurrency: exactly 10 of 15 simultaneous replies are published", %{
    discussion: d
  } do
    member = uuid()

    results =
      concurrently(
        for i <- 1..15,
            do: fn -> Posts.create_reply(viewer(member), d.slug, %{"body" => "Reply #{i}"}) end
      )

    assert Enum.count(results, &match?({:ok, %Reply{}}, &1)) == 10
    assert Enum.count(results, &(&1 == {:error, :rate_limited})) == 5
    assert unboxed(fn -> Repo.aggregate(where(Reply, author_id: ^member), :count) end) == 10
  end
end
