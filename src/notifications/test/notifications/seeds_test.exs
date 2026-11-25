defmodule MlNotifications.SeedsTest do
  use MlNotifications.DataCase, async: false
  import ExUnit.CaptureIO
  alias MlNotifications.{Notification, Setting}

  test "demo seeds are idempotent and only use public strings and identifiers" do
    run_seeds = fn -> capture_io(fn -> Code.eval_file("priv/repo/seeds.exs") end) end
    run_seeds.()
    first = Repo.aggregate(Notification, :count)
    run_seeds.()
    assert Repo.aggregate(Notification, :count) == first

    lea = MlShared.Demo.user("lea_moreau").id
    hugo = MlShared.Demo.user("hugo_bernard").id
    assert Repo.aggregate(where(Notification, user_id: ^lea), :count) == 5
    assert Repo.aggregate(where(Notification, user_id: ^hugo), :count) == 3

    assert Repo.aggregate(
             where(Notification, [n], n.user_id == ^lea and is_nil(n.read_at)),
             :count
           ) == 2

    # every seed is a valid notification of the catalog
    for n <- Repo.all(Notification) do
      spec = MlNotifications.Catalog.kind(n.kind)
      assert spec.category == n.category
      assert n.params |> Map.keys() |> Enum.all?(&Map.has_key?(spec.params, &1))
    end

    assert %Setting{quiet_enabled: true, time_zone: "Europe/Paris"} =
             Repo.get(Setting, MlShared.Demo.user("ines_petit").id)
  end
end
