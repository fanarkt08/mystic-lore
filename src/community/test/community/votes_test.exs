defmodule MlCommunity.VotesTest do
  use MlCommunity.DataCase, async: true
  alias MlCommunity.{Discussion, Vote, Votes}

  test "votes: the database itself refuses a second row for the same member and target" do
    row = %{
      user_id: uuid(),
      target_type: "reply",
      target_id: uuid(),
      inserted_at: DateTime.utc_now()
    }

    Repo.insert_all(Vote, [row])

    assert_raise Postgrex.Error, ~r/votes_pkey/, fn -> Repo.insert_all(Vote, [row]) end
  end

  test "no vote on one's own content nor on moderated content" do
    {author, voter} = {uuid(), uuid()}
    d = discussion!(author)
    assert {:error, :own_content} = Votes.set(viewer(author), d, true)

    assert {:error, :forbidden} =
             Votes.set(viewer(voter, staff: true), %{d | status: "hidden"}, true)

    assert {:ok, %{voted: true, helpful_count: 1}} = Votes.set(viewer(voter), d, true)
    assert Repo.get!(Discussion, d.id).helpful_count == 1
  end
end
