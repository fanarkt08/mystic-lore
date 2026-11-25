defmodule MlLearning.GamificationSeedsTest do
  use MlLearning.DataCase, async: true
  import ExUnit.CaptureIO
  alias MlLearning.Gamification.{Badge, Badges, Quest, UserBadge}

  defp seed, do: capture_io(fn -> Code.eval_file("priv/repo/seeds.exs") end)
  defp counts, do: for(s <- [Badge, Quest, UserBadge], do: Repo.aggregate(s, :count))

  defp slugs(user),
    do:
      Repo.all(
        from ub in UserBadge,
          join: b in assoc(ub, :badge),
          where: ub.user_id == ^user,
          order_by: b.slug,
          select: b.slug
      )

  defp equipped_slugs(user), do: for({badge, _} <- Badges.equipped(user), do: badge.slug)

  test "badges and quests are seeded once; demo members get the badges their real data earns" do
    output = seed()
    assert output =~ "10 badges, 3 daily quests"
    lea = MlShared.Demo.user("lea_moreau").id

    assert [10, 3, 5] = counts()

    assert slugs(lea) ==
             ~w(ember-keeper first-spark hundred-runes sprout-tender trailblazer)

    assert equipped_slugs(lea) == ~w(sprout-tender trailblazer ember-keeper)

    # les autres membres de démo n'ont aucune activité dans learning : aucun badge
    for %{username: name, id: id} <- MlShared.Demo.users(),
        name != "lea_moreau",
        do: assert(slugs(id) == [])

    # le choix d'un membre n'est jamais écrasé par un nouveau passage des seeds
    {:ok, _} = Badges.equip(lea, [Repo.get_by!(Badge, slug: "first-spark").id])
    first = counts()
    seed()
    assert counts() == first
    assert equipped_slugs(lea) == ["first-spark"]

    # icônes de la liste blanche uniquement (contrainte en base)
    assert_raise Postgrex.Error, fn ->
      Repo.transact(fn ->
        {:ok, Repo.update_all(from(b in Badge, where: b.slug == "archmage"), set: [icon: "x"])}
      end)
    end
  end
end
