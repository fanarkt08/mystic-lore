defmodule MlCommunity.Fixtures do
  @moduledoc "Données de test et faux services (accounts, social, centre de notifications)."
  import Ecto.Query
  alias MlCommunity.{Discussion, Posts, Repo, Viewer}

  def uuid, do: Ecto.UUID.generate()

  def viewer(id, opts \\ []),
    do: %Viewer{id: id, staff: Keyword.get(opts, :staff, false), blocked: opts[:blocked] || []}

  @doc "Installe de faux accounts, social et centre de notifications, et rapporte les écritures d'audit au test."
  def stub_services(opts \\ []) do
    test = self()

    config = %{
      staff: Keyword.get(opts, :staff, []),
      pairs: Keyword.get(opts, :blocks, []),
      restricted: Keyword.get(opts, :restricted, %{}),
      audit: Keyword.get(opts, :audit, :up),
      test: test
    }

    down = Keyword.get(opts, :down, [])

    Req.Test.stub(MlShared.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      [service] = Plug.Conn.get_req_header(conn, "x-ml-service")

      if service in down,
        do: Req.Test.transport_error(conn, :econnrefused),
        else: respond(conn, service, conn.path_info, config)
    end)
  end

  defp respond(conn, "accounts", ["api", "users"], _config) do
    ids = String.split(conn.query_params["ids"] || "", ",", trim: true)
    Req.Test.json(conn, %{"users" => Enum.map(ids, &fake_user/1)})
  end

  defp respond(conn, "accounts", ["api", "internal", "users", id], config) do
    role = if id in config.staff, do: "moderator", else: "user"

    Req.Test.json(conn, %{
      "user" =>
        Map.merge(fake_user(id), %{
          "role" => role,
          "confirmed" => true,
          "restricted_until" => config.restricted[id]
        })
    })
  end

  defp respond(conn, "accounts", ["api", "internal", "audit"], config) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    send(config.test, {:audit, Jason.decode!(raw)})

    if config.audit == :down,
      do: Req.Test.transport_error(conn, :econnrefused),
      else: conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})
  end

  # faux centre de notifications : chaque création est rapportée au test, `{:center, corps}`
  defp respond(conn, "notifications", ["api", "internal", "notifications"], config) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    send(config.test, {:center, Jason.decode!(raw)})
    conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"status" => "created"})
  end

  defp respond(conn, "social", ["api", "internal", "blocks", id], config) do
    ids = for {a, b} <- config.pairs, id in [a, b], do: if(a == id, do: b, else: a)
    Req.Test.json(conn, %{"user_ids" => ids})
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

  @doc "Vide le cache des rôles et blocages (à n'utiliser que dans les modules de test non asynchrones)."
  def clear_cache, do: :ets.delete_all_objects(MlCommunity.Cache)

  @doc "Discussion créée par les règles réelles (limite de débit comprise)."
  def discussion!(author, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          "category" => "help-questions",
          "title" => "Why does range(3) stop at 2?",
          "body" => "The grove only waters three saplings, numbered 0, 1 and 2."
        },
        attrs
      )

    {:ok, discussion} = Posts.create_discussion(viewer(author), attrs)
    discussion
  end

  def reply!(author, discussion, body \\ "It starts counting at zero, like the spirits.") do
    {:ok, reply} = Posts.create_reply(viewer(author), discussion.slug, %{"body" => body})
    reply
  end

  @doc "Insertion directe (sans limite de débit), pour les volumes : pagination, tris."
  def insert_discussion!(author, attrs \\ []) do
    title = attrs[:title] || "Discussion #{System.unique_integer([:positive])}"

    Repo.insert!(
      struct(
        %Discussion{
          author_id: author,
          category: "help-questions",
          title: title,
          slug: Discussion.slug(title),
          body: "A body long enough to be valid.",
          last_activity_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  @doc "Antidate une publication de `minutes` (fenêtre d'édition, limite de débit)."
  def age!(%schema{id: id}, minutes) do
    at = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)
    Repo.update_all(from(p in schema, where: p.id == ^id), set: [inserted_at: at])
  end

  @doc "Processus abonné à `\"user:<id>\"` qui relaie chaque événement au test : `{:event, user_id, message}`."
  def listen(user_id) do
    test = self()

    spawn_link(fn ->
      MlShared.Events.subscribe(MlShared.Events.user(user_id))
      send(test, {:listening, user_id})
      relay(test, user_id)
    end)

    receive do
      {:listening, ^user_id} -> :ok
    after
      1_000 -> raise "listener for #{user_id} not ready"
    end
  end

  defp relay(test, user_id) do
    receive do
      message -> send(test, {:event, user_id, message})
    end

    relay(test, user_id)
  end
end
