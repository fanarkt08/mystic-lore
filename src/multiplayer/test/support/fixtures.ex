defmodule MlMultiplayer.Fixtures do
  @moduledoc "Données de test (membres = UUID aléatoires : aucune collision entre tests) et faux services."
  alias MlMultiplayer.{Lobbies, MatchServer, Repo}

  def uuid, do: Ecto.UUID.generate()

  @doc "Installe de faux accounts, social et learning pour `MlShared.Client` et signale chaque appel au test."
  def stub_services(opts \\ []) do
    test = self()

    config =
      Map.new(
        Keyword.merge(
          [
            blocks: [],
            friends: :all,
            social: :up,
            learning: :up,
            accounts: :up,
            staff: [],
            restricted: %{},
            invites_closed: [],
            notifications: :up
          ],
          opts
        )
      )

    Req.Test.stub(MlShared.Client, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: nil, else: Jason.decode!(raw)
      send(test, {:service, conn.method, conn.request_path, body})
      respond(conn, body, config)
    end)
  end

  defp respond(%{request_path: "/api/users"} = conn, _body, _config) do
    ids = String.split(conn.query_params["ids"] || "", ",", trim: true)
    Req.Test.json(conn, %{"users" => Enum.map(ids, &fake_user/1)})
  end

  defp respond(%{request_path: "/api/internal/users/" <> _} = conn, _body, %{accounts: :down}),
    do: Req.Test.transport_error(conn, :econnrefused)

  defp respond(%{request_path: "/api/internal/users/" <> id} = conn, _body, config) do
    role = if id in config.staff, do: "moderator", else: "user"

    Req.Test.json(conn, %{
      "user" =>
        Map.merge(fake_user(id), %{"role" => role, "restricted_until" => config.restricted[id]})
    })
  end

  # faux centre de notifications (`notifications: :up | :down`)
  defp respond(%{request_path: "/api/internal/notifications" <> _} = conn, _body, config) do
    if config.notifications == :down,
      do: Req.Test.transport_error(conn, :econnrefused),
      else: conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"status" => "created"})
  end

  defp respond(%{request_path: "/api/internal/" <> _} = conn, _body, %{social: :down}),
    do: Req.Test.transport_error(conn, :econnrefused)

  defp respond(%{request_path: "/api/internal/blocks/" <> id} = conn, _body, config) do
    ids = for {a, b} <- config.blocks, id in [a, b], do: if(a == id, do: b, else: a)
    Req.Test.json(conn, %{"user_ids" => ids})
  end

  # permission d'inviter, comme social : blocage, puis amitié, puis réglage « personne » de l'invité
  defp respond(%{request_path: "/api/internal/can-contact"} = conn, _body, config) do
    %{"from" => from, "to" => to, "kind" => "lobby_invite"} = conn.query_params
    pair = fn list -> Enum.any?(list, &(&1 in [{from, to}, {to, from}])) end

    refusal =
      cond do
        pair.(config.blocks) -> "blocked"
        not (config.friends == :all or pair.(config.friends)) -> "not_friends"
        to in config.invites_closed -> "lobby_invites_closed"
        true -> nil
      end

    if refusal,
      do: conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => refusal}),
      else: Req.Test.json(conn, %{"allowed" => true})
  end

  defp respond(%{request_path: "/api/reports"} = conn, body, config) do
    cond do
      config.social == :down ->
        Req.Test.transport_error(conn, :econnrefused)

      body["reason"] in ~w(harassment spam inappropriate other) ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => uuid()})

      true ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{"error" => "invalid", "errors" => %{"reason" => ["is invalid"]}})
    end
  end

  defp respond(%{request_path: "/api/internal/xp"} = conn, _body, config) do
    case config.learning do
      :up ->
        Req.Test.json(conn, %{"xp" => "awarded"})

      :down ->
        Req.Test.transport_error(conn, :econnrefused)

      {:status, status} ->
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => "x"})
    end
  end

  def fake_user(id) do
    short = String.slice(id, 0, 8)

    %{
      "id" => id,
      "username" => "user_#{short}",
      "display_name" => "User #{short}",
      "avatar" => nil
    }
  end

  ## Salons et parties

  def lobby!(host, attrs \\ %{}) do
    defaults = %{"title" => "Rune night", "visibility" => "open", "max_players" => 4}
    {:ok, lobby} = Lobbies.create(host, Map.merge(defaults, attrs))
    lobby
  end

  def join!(lobby, user) do
    {:ok, :joined} = Lobbies.join(user, lobby.id)
    user
  end

  @doc "Salon de `count` joueurs prêts dont la partie est lancée : `%{lobby, match, players}` (hôte en tête)."
  def playing!(count \\ 2, attrs \\ %{}) do
    [host | others] = players = for _ <- 1..count, do: uuid()
    lobby = lobby!(host, attrs)
    Enum.each(others, &join!(lobby, &1))
    for user <- players, do: :ok = Lobbies.set_ready(user, lobby.id, true)
    {:ok, match} = Lobbies.start(host, lobby.id)
    %{lobby: Repo.reload!(lobby), match: match, players: players}
  end

  def engine(match_id) do
    {:ok, state} = MatchServer.state(match_id)
    state
  end

  @doc "Une séquence valide qui n'est pas le secret."
  def wrong_guess(secret), do: tl(secret) ++ [hd(secret)]

  @doc "Arrête le processus d'une partie et attend sa fin."
  def stop_server(match_id) do
    if pid = MatchServer.whereis(match_id) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> raise "match server did not stop"
      end
    end
  end
end
