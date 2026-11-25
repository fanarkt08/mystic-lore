# Vérifie l'export puis la suppression d'un membre jetable sur la pile de bin/dev, sans toucher aux comptes de démo.
#   cd src/shared && INTERNAL_SECRET=dev-internal-secret-not-for-production-0123456789abcdef \
#     elixir --sname privacy_smoke --cookie mysticlore-dev-cookie -S mix run ../../e2e/privacy_smoke.exs
alias MlShared.Client

defmodule Smoke do
  def web, do: System.get_env("WEB_URL", "http://localhost:4000")

  def check(name, fun) do
    case fun.() do
      :ok -> IO.puts("  ✓ " <> name)
      {:ok, _} -> IO.puts("  ✓ " <> name)
      other -> fail(name, inspect(other, limit: 12))
    end
  rescue
    e -> fail(name, Exception.message(e))
  end

  defp fail(name, why) do
    IO.puts("  ✗ #{name} → #{why}")
    Process.put(:failed, true)
  end

  def wait(fun, tries \\ 60) do
    case fun.() do
      {:ok, value} -> {:ok, value}
      _ when tries > 0 -> Process.sleep(1_000) && wait(fun, tries - 1)
      other -> {:timeout, other}
    end
  end

  # Inscription réelle + lien de confirmation lu dans la boîte de dev d'accounts.
  def member(tag, stamp) do
    email = "privacy_#{tag}_#{stamp}@mysticlore.test"
    username = "privacy_#{tag}_#{stamp}"
    password = "privacy-pass-#{stamp}"

    {:ok, %{"user" => %{"id" => id}}} =
      Client.post(:accounts, "/api/users",
        json: %{email: email, password: password, username: username, display_name: "Privacy #{tag}"}
      )

    {:ok, mails} = Req.get(Client.base_url(:accounts) <> "/dev/mailbox/json", retry: false)

    %{"text_body" => body} =
      Enum.find(mails.body["data"], fn m -> Enum.any?(m["to"], &String.contains?(inspect(&1), email)) end)

    [_, token] = Regex.run(~r{/confirm/([A-Za-z0-9_\-]+)}, body)
    {:ok, _} = Client.post(:accounts, "/api/users/confirm", json: %{token: token})
    %{id: id, email: email, username: username, password: password}
  end

  # Connexion par le formulaire du navigateur (jeton CSRF + cookie de session signé de web).
  def web_login(m) do
    {:ok, page} = Req.get(web() <> "/login", retry: false)
    cookie = cookie(page)
    [_, csrf] = Regex.run(~r/name="_csrf_token"[^>]* value="([^"]+)"/, page.body)

    {:ok, resp} =
      Req.post(web() <> "/login",
        form: [{"_csrf_token", csrf}, {"user[email]", m.email}, {"user[password]", m.password}],
        headers: [{"cookie", cookie}],
        redirect: false,
        retry: false
      )

    302 = resp.status
    cookie(resp)
  end

  defp cookie(resp), do: resp.headers["set-cookie"] |> List.first() |> String.split(";") |> hd()

  @doc "PNG réel (IDAT zlib) avec un chunk texte que social doit retirer."
  def png(w, h) do
    chunk = fn type, data ->
      <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
    end

    rows = for _ <- 1..h, into: <<>>, do: <<0>> <> :binary.copy(<<40, 60, 140>>, w)

    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <>
      chunk.("IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>) <>
      chunk.("tEXt", "Comment\0PRIVACY-SECRET") <>
      chunk.("IDAT", :zlib.compress(rows)) <> chunk.("IEND", "")
  end
end

{:ok, host} = :inet.gethostname()
accounts_node = :"accounts@#{host}"
Node.connect(accounts_node) || (IO.puts("✗ cluster injoignable (bin/dev ?)") && System.halt(1))
Process.sleep(500)

stamp = System.unique_integer([:positive]) |> Integer.to_string(36) |> String.downcase()
a = Smoke.member("a", stamp)
b = Smoke.member("b", stamp)
IO.puts("membres jetables : A=#{a.username} (#{a.id}) · B=#{b.username} (#{b.id})")

IO.puts("activité de A (et de B, pour le périmètre)")

Smoke.check("learning : leçon terminée et note", fn ->
  {:ok, %{"entries" => adventures}} = Client.get(:learning, "/api/adventures", params: [access: "free"])

  story =
    Enum.find_value(adventures, fn %{"slug" => slug} ->
      {:ok, %{"chapters" => chapters}} = Client.get(:learning, "/api/adventures/#{slug}", as: a.id)
      chapters |> Enum.flat_map(& &1["lessons"]) |> Enum.find(&(&1["kind"] == "story"))
    end)
  {:ok, _} = Client.get(:learning, "/api/lessons/#{story["id"]}", as: a.id)
  {:ok, %{"xp" => _}} = Client.post(:learning, "/api/lessons/#{story["id"]}/complete", as: a.id)
  Client.put(:learning, "/api/lessons/#{story["id"]}/notes", as: a.id, json: %{notes: "A's private note #{stamp}"})
end)

# une demande envoyée par le formulaire de contact ; l'accusé ne reprend pas le texte
Smoke.check("support : demande de A, accusé de réception sans le texte soumis", fn ->
  {:ok, %{"request" => %{"id" => id, "reference" => ref}, "acknowledgement" => "sent"}} =
    Client.post(:accounts, "/api/support/requests",
      as: a.id,
      json: %{topic: "privacy", message: "A asks about the retention #{stamp}", locale: "en"}
    )

  Process.put(:support, id)
  {:ok, mails} = Req.get(Client.base_url(:accounts) <> "/dev/mailbox/json", retry: false)
  ack = Enum.find(mails.body["data"], &(inspect(&1["to"]) =~ a.email and &1["subject"] =~ ref))
  true = ack != nil and not String.contains?(Jason.encode!(ack), "A asks about the retention")
  :ok
end)

Smoke.check("social : amis, messages des deux côtés, image de A (pièce jointe), réglage de A", fn ->
  {:ok, %{"id" => request}} = Client.post(:social, "/api/friend-requests", as: a.id, json: %{user_id: b.id})
  {:ok, _} = Client.post(:social, "/api/friend-requests/#{request}/accept", as: b.id)
  {:ok, %{"conversation" => %{"id" => c}}} = Client.post(:social, "/api/conversations", as: a.id, json: %{user_id: b.id})
  Process.put(:conversation, c)
  {:ok, _} = Client.post(:social, "/api/conversations/#{c}/messages", as: a.id, json: %{body: "Message from A #{stamp}"})

  {:ok, %{"message" => %{"attachment" => %{"id" => attachment, "scan" => "unscanned"}}}} =
    Client.post(:social, "/api/conversations/#{c}/messages",
      as: a.id,
      json: %{body: "A's picture", attachment: %{data_base64: Base.encode64(Smoke.png(24, 16)), filename: "privacy.png", alt: "A picture"}}
    )

  Process.put(:attachment, attachment)
  {:ok, <<0x89, "PNG", _::binary>> = served} = Client.get(:social, "/api/attachments/#{attachment}", as: b.id, decode_body: false)
  false = served =~ "PRIVACY-SECRET"
  {:ok, _} = Client.patch(:social, "/api/me/settings", as: a.id, json: %{friend_requests: "friends_of_friends"})
  Client.post(:social, "/api/conversations/#{c}/messages", as: b.id, json: %{body: "Reply from B #{stamp}"})
end)

Smoke.check("community : discussion de A, réponse de B", fn ->
  {:ok, %{"discussion" => %{"slug" => slug}}} =
    Client.post(:community, "/api/discussions",
      as: a.id,
      json: %{category: "off-topic", title: "A asks about privacy #{stamp}", body: "Discussion body written by A."}
    )

  Process.put(:discussion, slug)
  Client.post(:community, "/api/discussions/#{slug}/replies", as: b.id, json: %{body: "Answer by B #{stamp}"})
end)

Smoke.check("multiplayer : salon de A, chat des deux", fn ->
  {:ok, %{"lobby" => %{"id" => lobby}}} =
    Client.post(:multiplayer, "/api/lobbies", as: a.id, json: %{title: "Privacy relay", max_players: 2, visibility: "open"})

  Process.put(:lobby, lobby)
  {:ok, _} = Client.post(:multiplayer, "/api/lobbies/#{lobby}/join", as: b.id)
  {:ok, _} = Client.post(:multiplayer, "/api/lobbies/#{lobby}/messages", as: a.id, json: %{body: "Lobby line from A"})
  Client.post(:multiplayer, "/api/lobbies/#{lobby}/messages", as: b.id, json: %{body: "Lobby line from B"})
end)

Smoke.check("studio : brouillon solo + projet partagé avec B + génération IA (crédits)", fn ->
  {:ok, %{"project" => %{"id" => solo}}} = Client.post(:studio, "/api/projects", as: a.id, json: %{title: "A solo draft"})
  {:ok, %{"project" => %{"id" => shared}}} = Client.post(:studio, "/api/projects", as: a.id, json: %{title: "A and B course"})
  Process.put(:projects, {solo, shared})
  {:ok, _} = Client.post(:studio, "/api/projects/#{shared}/collaborators", as: a.id, json: %{username: b.username, role: "editor"})

  {:ok, %{"generation" => %{"id" => g}}} =
    Client.post(:studio, "/api/projects/#{solo}/generations", as: a.id, json: %{kind: "outline", brief: "A garden of loops", confirm_cost: 2})

  Smoke.wait(fn ->
    case Client.get(:studio, "/api/projects/#{solo}/generations", as: a.id) do
      {:ok, %{"generations" => [%{"id" => ^g, "credits" => "consumed"}]}} -> {:ok, g}
      _ -> :retry
    end
  end)
end)

Smoke.check("billing : abonnement premium (paiement local simulé, webhook signé) + facture", fn ->
  {:ok, %{"session_id" => sid}} =
    Client.post(:billing, "/api/checkout",
      as: a.id,
      json: %{plan: "premium", success_url: "http://localhost:4000/membership/success?session_id={CHECKOUT_SESSION_ID}", cancel_url: "http://localhost:4000/membership/cancel"}
    )

  {:ok, _} = Client.post(:billing, "/api/checkout/#{sid}/simulate-payment", as: a.id, json: %{outcome: "succeeded"})

  Smoke.wait(fn ->
    case Client.get(:billing, "/api/entitlements/#{a.id}") do
      {:ok, %{"plan" => "premium", "status" => "active"}} = ok -> ok
      _ -> :retry
    end
  end)
end)

IO.puts("routes internes")

Smoke.check("un appelant autre qu'accounts reçoit 403 partout", fn ->
  for s <- [:learning, :billing, :social, :multiplayer, :community, :studio, :notifications] do
    {:error, {:http, 403, _}} = Client.get(s, "/api/internal/users/#{a.id}/export")
    {:error, {:http, 403, _}} = Client.delete(s, "/api/internal/users/#{a.id}")
  end

  :ok
end)

IO.puts("export")
MlShared.Events.subscribe("user:#{a.id}")
cookie_a = Smoke.web_login(a)

export_id =
  case Client.post(:accounts, "/api/me/exports", as: a.id, json: %{password: a.password}) do
    {:ok, %{"id" => id}} -> id
    other -> raise "export refused: #{inspect(other)}"
  end

Smoke.check("mot de passe faux → 401", fn ->
  {:error, {:http, 401, _}} = Client.post(:accounts, "/api/me/exports", as: a.id, json: %{password: "nope-nope-nope"})
  :ok
end)

Smoke.check("tâche asynchrone → ready (événement temps réel reçu)", fn ->
  receive do
    {:data_export_changed, _} -> :ok
  after
    5_000 -> :no_event
  end

  Smoke.wait(fn ->
    case Client.get(:accounts, "/api/me/exports", as: a.id) do
      {:ok, %{"exports" => [%{"id" => ^export_id, "status" => "ready"} | _]}} = ok -> ok
      _ -> :retry
    end
  end)
end)

Smoke.check("téléchargement par web (/settings/exports/:id/download) : pièce jointe JSON complète", fn ->
  {:ok, resp} =
    Req.get(Smoke.web() <> "/settings/exports/#{export_id}/download",
      headers: [{"cookie", cookie_a}],
      redirect: false,
      decode_body: false,
      retry: false
    )

  200 = resp.status
  ["attachment; filename=\"mysticlore-data-" <> _] = resp.headers["content-disposition"]
  doc = Jason.decode!(resp.body)
  s = doc["services"]
  true = Enum.sort(Map.keys(s)) == ~w(accounts billing community learning multiplayer notifications social studio)
  true = s["accounts"]["profile"]["email"] == a.email
  [%{"message" => "A asks about the retention " <> _, "topic" => "privacy"}] = s["accounts"]["support_requests"]
  %{"status" => "pending"} = s["accounts"]["onboarding"]
  [%{"notes" => "A's private note " <> _} | _] = Enum.filter(s["learning"]["lesson_progress"], & &1["notes"])
  [_ | _] = s["learning"]["xp_events"]
  [%{"user_id" => bid, "username" => bname}] = s["social"]["friends"]
  true = bid == b.id and bname == b.username
  ["Message from A " <> _, "A's picture"] = Enum.map(s["social"]["messages_sent"], & &1["body"])
  [%{"filename" => "privacy.png", "alt_text" => "A picture", "data_base64" => picture}] = s["social"]["attachments_sent"]
  {:ok, <<0x89, "PNG", _::binary>>} = Base.decode64(picture)
  %{"friend_requests" => "friends_of_friends"} = s["social"]["settings"]
  [%{"title" => "A asks about privacy " <> _}] = s["community"]["discussions"]
  ["Lobby line from A"] = Enum.map(s["multiplayer"]["messages_sent"], & &1["body"])
  ["A and B course", "A solo draft"] = s["studio"]["projects"] |> Enum.map(& &1["title"]) |> Enum.sort()
  [%{"credits" => "consumed"}] = s["studio"]["generations"]
  %{"plan" => "premium", "status" => "active"} = s["billing"]["subscription"]
  [_ | _] = s["billing"]["invoices"]
  [_ | _] = s["billing"]["credits"]["ledger"]
  # centre de notifications : les notifications reçues par A (jamais celles de B), sans texte de message
  kinds = Enum.map(s["notifications"]["notifications"], & &1["kind"])
  true = "friend_request_accepted" in kinds and "message_received" in kinds
  false = "friend_request_received" in kinds
  raw = resp.body
  false = raw =~ "Reply from B" or raw =~ "Lobby line from B" or raw =~ "Answer by B"
  IO.puts("    #{byte_size(raw)} octets · sections : #{Enum.join(Map.keys(s), ", ")}")
  :ok
end)

Smoke.check("IDOR : B ne télécharge pas l'export de A (renvoi vers /settings/data, qui l'explique)", fn ->
  cookie_b = Smoke.web_login(b)

  {:ok, resp} =
    Req.get(Smoke.web() <> "/settings/exports/#{export_id}/download",
      headers: [{"cookie", cookie_b}],
      redirect: false,
      retry: false
    )

  302 = resp.status
  # l'état est expliqué par la section des données (« This export doesn't exist »), rien n'est servi
  ["/settings/data?export=missing"] = resp.headers["location"]
  {:error, {:http, 404, _}} = Client.get(:accounts, "/api/me/exports/#{export_id}/download", as: b.id)
  :ok
end)

IO.puts("suppression")

Smoke.check("pseudonyme faux → 422 ; programmée à J+30, sessions révoquées, e-mail", fn ->
  {:error, {:http, 422, _}} =
    Client.post(:accounts, "/api/me/deletion", as: a.id, json: %{password: a.password, confirm_username: "someone"})

  {:ok, %{"deletion_scheduled_at" => at}} =
    Client.post(:accounts, "/api/me/deletion", as: a.id, json: %{password: a.password, confirm_username: a.username})

  {:ok, at, _} = DateTime.from_iso8601(at)
  true = abs(DateTime.diff(at, DateTime.utc_now()) - 30 * 86_400) < 120

  receive do
    {:sessions_revoked, _} -> :ok
  after
    5_000 -> raise "no sessions_revoked event"
  end

  {:ok, page} = Req.get(Smoke.web() <> "/dashboard", headers: [{"cookie", cookie_a}], redirect: false, retry: false)
  302 = page.status
  {:ok, mails} = Req.get(Client.base_url(:accounts) <> "/dev/mailbox/json", retry: false)
  true = Enum.any?(mails.body["data"], &(&1["subject"] == "Your MysticLore account will be deleted" and inspect(&1["to"]) =~ a.email))
  :ok
end)

Smoke.check("pendant le délai : connexion possible (date renvoyée), annulation, reprogrammation", fn ->
  {:ok, %{"user" => %{"deletion_scheduled_at" => at}}} =
    Client.post(:accounts, "/api/sessions", json: %{email: a.email, password: a.password})

  true = is_binary(at)
  {:ok, _} = Client.delete(:accounts, "/api/me/deletion", as: a.id)
  {:error, {:http, 404, _}} = Client.delete(:accounts, "/api/me/deletion", as: a.id)
  {:ok, _} = Client.post(:accounts, "/api/me/deletion", as: a.id, json: %{password: a.password, confirm_username: a.username})
  :ok
end)

Smoke.check("échéance mise dans le passé (base de dev) puis exécuteur (Oban) → compte anonymisé", fn ->
  uuid = Base.decode16!(String.replace(a.id, "-", ""), case: :lower)

  %{num_rows: 1} =
    :rpc.call(accounts_node, Ecto.Adapters.SQL, :query!, [
      MlAccounts.Repo,
      "UPDATE users SET deletion_scheduled_at = now() - interval '1 minute' WHERE id = $1",
      [uuid]
    ])

  {:error, {:http, 403, %{"error" => "account_deleted"}}} =
    Client.post(:accounts, "/api/sessions", json: %{email: a.email, password: a.password})

  n = :rpc.call(accounts_node, MlAccounts.Privacy, :enqueue_due_deletions, [])
  IO.puts("    suppressions dues mises en file : #{n}")

  Smoke.wait(fn ->
    case Client.get(:accounts, "/api/users", params: [ids: a.id]) do
      {:ok, %{"users" => [%{"display_name" => "Deleted member"} = u]}} -> {:ok, u}
      _ -> :retry
    end
  end)
end)

Smoke.check("après : connexion refusée, profil « Deleted member », plus de page par pseudonyme", fn ->
  {:error, {:http, 401, _}} = Client.post(:accounts, "/api/sessions", json: %{email: a.email, password: a.password})
  {:error, {:http, 404, _}} = Client.get(:accounts, "/api/users/by-username/#{a.username}")
  {:ok, %{"users" => [%{"username" => "deleted_" <> _, "display_name" => "Deleted member", "avatar" => nil}]}} =
    Client.get(:accounts, "/api/users", params: [ids: a.id])
  # B voit toujours la discussion de A, signée « Deleted member »
  {:ok, %{"discussion" => %{"author" => %{"display_name" => "Deleted member"}}}} =
    Client.get(:community, "/api/discussions/#{Process.get(:discussion)}", as: b.id)

  # social : le message de A reste, son fichier est effacé (plus servi, « pièce jointe supprimée »)
  {:ok, %{"entries" => thread}} = Client.get(:social, "/api/conversations/#{Process.get(:conversation)}/messages", as: b.id)
  %{"attachment" => %{"available" => false, "filename" => nil}} = Enum.find(thread, &(&1["body"] == "A's picture"))
  {:error, {:http, 404, _}} = Client.get(:social, "/api/attachments/#{Process.get(:attachment)}", as: b.id)

  {:ok, %{"entries" => entries}} = Client.get(:multiplayer, "/api/lobbies/#{Process.get(:lobby)}/messages", as: b.id)
  true = Enum.any?(entries, &(&1["user"]["display_name"] == "Deleted member"))
  {:ok, %{"plan" => "free", "status" => "canceled"}} = Client.get(:billing, "/api/entitlements/#{a.id}")
  {solo, shared} = Process.get(:projects)
  {:ok, %{"project" => %{"owner_id" => nil, "role" => "editor"}}} = Client.get(:studio, "/api/projects/#{shared}", as: b.id)
  {:error, {:http, 404, _}} = Client.get(:studio, "/api/projects/#{solo}", as: a.id)
  # la demande de support de A est partie avec son compte
  nil = :rpc.call(accounts_node, MlAccounts.Repo, :get, [MlAccounts.SupportRequest, Process.get(:support)])
  :ok
end)

Smoke.check("notifications : celles de A effacées ; chez B, celles dont A est l'acteur restent (« Deleted member »)", fn ->
  {:ok, %{"entries" => [], "unread" => 0}} = Client.get(:notifications, "/api/me/notifications", as: a.id)
  {:ok, %{"entries" => entries}} = Client.get(:notifications, "/api/me/notifications", as: b.id)
  from_a = Enum.filter(entries, &(&1["actor_id"] == a.id))
  true = from_a != [] and Enum.all?(from_a, &(&1["actor"]["display_name"] == "Deleted member"))
  :ok
end)

IO.puts("A_ID=#{a.id}")
IO.puts("B_ID=#{b.id}")
if Process.get(:failed), do: System.halt(1), else: IO.puts("PRIVACY SMOKE OK")
