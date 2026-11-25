defmodule MlSocial.ConcurrencyTest do
  @moduledoc """
  Courses réelles : chaque opération tourne hors sandbox, sur sa propre connexion et dans sa propre
  transaction validée. Les membres sont des UUID aléatoires ; leurs lignes sont supprimées à la fin.
  """
  use ExUnit.Case, async: false
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias MlSocial.{Block, Chat, Conversation, Friends, Friendship, Member, Repo}

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # faux accounts et faux centre de notifications (les tâches de la course le trouvent par `$callers`)
  setup do
    Req.Test.stub(MlShared.Client, &MlSocialWeb.ConnCase.fake_accounts/1)
    :ok
  end

  defp concurrently(funs) do
    funs
    |> Task.async_stream(&unboxed/1, max_concurrency: 10, timeout: 30_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp members(n) do
    ids = for _ <- 1..n, do: Ecto.UUID.generate()

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(
          from f in Friendship, where: f.requester_id in ^ids or f.addressee_id in ^ids
        )

        Repo.delete_all(from b in Block, where: b.blocker_id in ^ids or b.blocked_id in ^ids)
        Repo.delete_all(from c in Conversation, where: c.user_low in ^ids or c.user_high in ^ids)
      end)
    end)

    ids
  end

  defp pair_rows(a, b) do
    unboxed(fn ->
      Repo.all(
        from f in Friendship,
          where: f.requester_id in [^a, ^b] and f.addressee_id in [^a, ^b]
      )
    end)
  end

  test "demandes croisées simultanées : une seule ligne, acceptée (acceptation mutuelle)" do
    pairs = members(20) |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1)

    results =
      concurrently(
        for {a, b} <- pairs,
            {from, to} <- [{a, b}, {b, a}],
            do: fn -> Friends.send_request(from, to) end
      )

    for {{a, b}, [first, second]} <- Enum.zip(pairs, Enum.chunk_every(results, 2)) do
      statuses = Enum.sort(for {:ok, %Friendship{status: s}} <- [first, second], do: s)
      assert statuses == ["accepted", "pending"]
      assert [%Friendship{status: "accepted"}] = pair_rows(a, b)
    end
  end

  test "demandes identiques simultanées : une seule demande en attente" do
    [a, b] = members(2)
    results = concurrently(for _ <- 1..8, do: fn -> Friends.send_request(a, b) end)

    assert Enum.count(results, &match?({:ok, %Friendship{status: "pending"}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_requested})) == 7
    assert [%Friendship{status: "pending", requester_id: ^a}] = pair_rows(a, b)
  end

  test "blocage simultané d'une demande : aucune demande ne survit au blocage" do
    pairs = members(20) |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1)

    concurrently(
      for {a, b} <- pairs,
          fun <- [fn -> Friends.block(a, b) end, fn -> Friends.send_request(b, a) end],
          do: fun
    )

    for {a, b} <- pairs do
      assert pair_rows(a, b) == []
      assert unboxed(fn -> Friends.blocked?(a, b) end)
    end
  end

  test "ouverture simultanée : une seule conversation (et deux membres) par paire" do
    [a, b] = members(2)

    unboxed(fn ->
      {:ok, %{id: id}} = Friends.send_request(a, b)
      {:ok, _} = Friends.accept(b, id)
    end)

    results =
      concurrently(
        for i <- 1..10,
            do: fn -> if rem(i, 2) == 0, do: Chat.open(a, b), else: Chat.open(b, a) end
      )

    assert [id] = results |> Enum.map(fn {:ok, %{conversation: c}} -> c.id end) |> Enum.uniq()

    unboxed(fn ->
      assert Repo.aggregate(from(c in Conversation, where: c.user_low in [^a, ^b]), :count) == 1
      assert Repo.aggregate(from(m in Member, where: m.conversation_id == ^id), :count) == 2
    end)
  end
end
