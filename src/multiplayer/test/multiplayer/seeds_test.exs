defmodule MlMultiplayer.SeedsTest do
  # UUID fixes de démonstration partagés : pas d'exécution concurrente avec d'autres tests.
  use MlMultiplayer.DataCase, async: false
  import ExUnit.CaptureIO
  alias MlMultiplayer.{Lobbies, Lobby, MatchEvent, Member, Message, Reward}

  defp run_seeds, do: capture_io(fn -> Code.eval_file("priv/repo/seeds.exs") end)

  test "seeds idempotents : salon ouvert de Hugo, partie terminée de Léa et Inès avec son journal" do
    [lea, hugo, ines] =
      Enum.map(~w(lea_moreau hugo_bernard ines_petit), &MlShared.Demo.user(&1).id)

    schemas = [Lobby, Member, Message, MatchEvent, Reward]

    run_seeds()
    counts = for schema <- schemas, do: Repo.aggregate(schema, :count)
    run_seeds()
    assert counts == for(schema <- schemas, do: Repo.aggregate(schema, :count))

    assert {:ok, %{entries: [%{lobby: %Lobby{title: "Relais du soir", host_id: ^hugo}}]}} =
             Lobbies.list_open(lea, 1)

    assert [%{lobby: %Lobby{title: "Relais entre amies"}, role: :host}] = Lobbies.list_mine(lea)
    {:ok, detail} = Lobbies.detail(ines, "00000000-0000-4000-8000-00000000b002")
    assert %{"status" => "won", "attempts" => [_, _], "secret" => [_, _, _, _, _]} = detail.match
    assert detail.match["my_hints"] != []
    assert Repo.aggregate(MatchEvent, :count) == 4
    assert Enum.sort(Repo.all(from r in Reward, select: r.user_id)) == Enum.sort([lea, ines])
    assert {:error, :not_found} = Lobbies.fetch(hugo, "00000000-0000-4000-8000-00000000b002")
  end
end
