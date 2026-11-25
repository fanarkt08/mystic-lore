defmodule MlMultiplayer.ChatTest do
  use MlMultiplayer.DataCase, async: true
  alias MlMultiplayer.{Chat, Message}

  setup do
    host = uuid()
    lobby = lobby!(host)
    %{host: host, lobby: lobby, guest: join!(lobby, uuid())}
  end

  test "membres seulement ; 1 à 500 caractères ; diffusion sans contenu", %{
    lobby: lobby,
    host: host
  } do
    MlShared.Events.subscribe("lobby:#{lobby.id}")
    lobby_id = lobby.id

    assert {:error, :forbidden} = Chat.post(uuid(), lobby.id, %{"body" => "hi"})
    assert {:error, :forbidden} = Chat.list(uuid(), lobby.id, nil)
    assert {:error, changeset} = Chat.post(host, lobby.id, %{"body" => "   "})
    assert %{body: ["can't be blank"]} = errors_on(changeset)

    assert {:error, changeset} =
             Chat.post(host, lobby.id, %{"body" => String.duplicate("é", 501)})

    assert %{body: [_]} = errors_on(changeset)

    assert {:ok, %Message{body: "Moon is first!"}} =
             Chat.post(host, lobby.id, %{"body" => "  Moon is first!  "})

    assert_receive {:chat_posted, ^lobby_id}
    assert {:ok, %{entries: [%Message{body: "Moon is first!"}]}} = Chat.list(host, lobby.id, nil)
  end

  test "limite de débit en base : 5 messages par 10 s et par membre", %{
    lobby: lobby,
    host: host,
    guest: guest
  } do
    now = DateTime.utc_now()

    for i <- 1..5,
        do:
          {:ok, _} =
            Chat.post(host, lobby.id, %{"body" => "m#{i}"}, DateTime.add(now, i, :millisecond))

    assert {:error, :rate_limited} =
             Chat.post(host, lobby.id, %{"body" => "six"}, DateTime.add(now, 1))

    # la limite est propre à chaque membre, et la fenêtre glisse
    assert {:ok, _} = Chat.post(guest, lobby.id, %{"body" => "me too"}, DateTime.add(now, 1))
    assert {:ok, _} = Chat.post(host, lobby.id, %{"body" => "later"}, DateTime.add(now, 11))
  end

  test "lecture filtrée côté serveur : blocage dans un sens ou dans l'autre", %{
    lobby: lobby,
    host: host,
    guest: guest
  } do
    third = join!(lobby, uuid())

    for {user, body} <- [{host, "from host"}, {guest, "from guest"}, {third, "from third"}],
        do: {:ok, _} = Chat.post(user, lobby.id, %{"body" => body})

    stub_services(blocks: [{host, guest}])

    bodies = fn user ->
      {:ok, %{entries: entries}} = Chat.list(user, lobby.id, nil)
      Enum.map(entries, & &1.body)
    end

    assert bodies.(host) == ["from host", "from third"]
    assert bodies.(guest) == ["from guest", "from third"]
    assert bodies.(third) == ["from host", "from guest", "from third"]

    stub_services(social: :down)
    assert {:error, :social_unavailable} = Chat.list(third, lobby.id, nil)
  end

  test "pagination par curseur, ordre chronologique", %{lobby: lobby, host: host} do
    now = DateTime.utc_now()

    rows =
      for i <- 1..55 do
        %{
          id: uuid(),
          lobby_id: lobby.id,
          user_id: host,
          body: "message #{i}",
          inserted_at: DateTime.add(now, i - 100)
        }
      end

    Repo.insert_all(Message, rows)
    {:ok, %{entries: page, next_before: before}} = Chat.list(host, lobby.id, nil)
    assert length(page) == 50
    assert hd(page).body == "message 6" and List.last(page).body == "message 55"

    {:ok, %{entries: older, next_before: nil}} = Chat.list(host, lobby.id, before)
    assert Enum.map(older, & &1.body) == for(i <- 1..5, do: "message #{i}")
    assert {:error, {:invalid, %{before: _}}} = Chat.list(host, lobby.id, uuid())
  end
end
