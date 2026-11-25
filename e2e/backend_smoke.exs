# Test de fumée entre services, exécuté comme un nœud qui rejoint le cluster de bin/dev :
#   cd src/shared && INTERNAL_SECRET=<secret de dev> elixir --sname smoke --cookie <cookie> -S mix run ../../e2e/backend_smoke.exs
alias MlShared.{Client, Demo, Events}

defmodule Smoke do
  def check(name, fun) do
    case fun.() do
      :ok -> IO.puts("  ✓ " <> name)
      {:ok, _} -> IO.puts("  ✓ " <> name)
      other -> IO.puts("  ✗ " <> name <> " → " <> inspect(other, limit: 8)); Process.put(:failed, true)
    end
  rescue
    e -> IO.puts("  ✗ " <> name <> " → " <> Exception.message(e)); Process.put(:failed, true)
  end
end

lea = Demo.user("lea_moreau")
hugo = Demo.user("hugo_bernard")

# rejoindre le cluster lancé par bin/dev, sans quoi aucun événement ne peut arriver
{:ok, host} = :inet.gethostname()
services = for s <- ~w(web accounts learning billing social notifications), do: :"#{s}@#{host}"
Enum.each(services, &Node.connect/1)
connected = Enum.filter(services, &(&1 in Node.list()))
IO.puts("cluster: #{inspect(connected)}")

unless Enum.all?(~w(accounts learning billing social)a, fn s -> :"#{s}@#{host}" in connected end) do
  IO.puts("✗ impossible de rejoindre le cluster (services lancés avec bin/dev ? même cookie ?)")
  System.halt(1)
end

IO.puts("accounts")
Smoke.check("login lea (mot de passe de démo) → jeton de session", fn ->
  {:ok, %{"session_token" => t, "user" => %{"id" => id}}} = Client.post(:accounts, "/api/sessions", json: %{email: lea.email, password: Demo.password()})
  true = id == lea.id
  {:ok, %{"user" => %{"username" => "lea_moreau"}}} = Client.get(:accounts, "/api/sessions/current", headers: [{"x-session-token", t}])
  :ok
end)
Smoke.check("identifiants invalides → 401 (adresse jetable : ne verrouille aucun compte de démo)", fn ->
  email = "nobody_#{System.unique_integer([:positive])}@mysticlore.test"
  {:error, {:http, 401, %{"error" => "invalid_credentials"}}} = Client.post(:accounts, "/api/sessions", json: %{email: email, password: "wrong-password-xx"})
  :ok
end)

stamp = System.unique_integer([:positive]) |> Integer.to_string(36) |> String.downcase()

{:ok, %{"user" => %{"id" => newbie_id}}} =
  Client.post(:accounts, "/api/users",
    json: %{email: "smoke_#{stamp}@mysticlore.test", password: "smoke-password-#{stamp}", username: "smoke_#{stamp}"}
  )

newbie = %{id: newbie_id}
IO.puts("membre neuf (gratuit) : smoke_#{stamp}")

IO.puts("learning ↔ billing")
Smoke.check("lea (premium seedé dans billing) ouvre une leçon premium", fn ->
  {:ok, %{"access" => "open", "chapters" => [%{"lessons" => [l | _]} | _]}} = Client.get(:learning, "/api/adventures/la-machine-de-l-alchimiste", as: lea.id)
  {:ok, %{"lesson" => %{"id" => _}}} = Client.get(:learning, "/api/lessons/#{l["id"]}", as: lea.id)
  :ok
end)

{:ok, %{"chapters" => [%{"lessons" => [premium_lesson | _]} | _]}} = Client.get(:learning, "/api/adventures/la-machine-de-l-alchimiste", as: newbie.id)
Smoke.check("membre neuf (free) refusé : 402 premium_required (et mis en cache côté learning)", fn ->
  {:error, {:http, 402, %{"error" => "premium_required"}}} = Client.post(:learning, "/api/adventures/la-machine-de-l-alchimiste/enroll", as: newbie.id)
  :ok
end)

IO.puts("billing (mode local) → événement cluster → learning")
Events.subscribe(Events.user(newbie.id))
web = "http://localhost:4000"
{:ok, plans} = Client.get(:billing, "/api/plans")
IO.puts("  mode de paiement : #{plans["mode"]}")
target = "premium"

Smoke.check("checkout #{target} → simulate-payment → droits activés par webhook signé", fn ->
  {:ok, %{"session_id" => sid, "url" => url}} =
    Client.post(:billing, "/api/checkout", as: newbie.id, json: %{plan: target, success_url: web <> "/membership/success?session_id={CHECKOUT_SESSION_ID}", cancel_url: web <> "/membership/cancel"})
  true = String.contains?(url, sid)
  {:ok, %{"status" => "open"}} = Client.get(:billing, "/api/checkout/#{sid}", as: newbie.id)
  {:ok, _} = Client.post(:billing, "/api/checkout/#{sid}/simulate-payment", as: newbie.id, json: %{outcome: "succeeded"})
  {:ok, %{"status" => "completed"}} = Client.get(:billing, "/api/checkout/#{sid}", as: newbie.id)
  {:ok, %{"plan" => ^target, "status" => "active"}} = Client.get(:billing, "/api/entitlements/#{newbie.id}")
  :ok
end)
Smoke.check("événement {:entitlements_changed, membre neuf, #{target}} reçu via le cluster", fn ->
  receive do
    {:entitlements_changed, id, plan} when id == newbie.id and plan == target -> :ok
  after
    3_000 -> {:error, :no_event}
  end
end)
Smoke.check("learning a invalidé son cache : le membre ouvre maintenant la leçon premium (sans attendre 30 s)", fn ->
  {:ok, %{"enrolled" => true}} = Client.post(:learning, "/api/adventures/la-machine-de-l-alchimiste/enroll", as: newbie.id)
  {:ok, %{"lesson" => _}} = Client.get(:learning, "/api/lessons/#{premium_lesson["id"]}", as: newbie.id)
  :ok
end)
Smoke.check("l'URL de retour seule n'active rien (session inconnue → 404)", fn ->
  {:error, {:http, 404, _}} = Client.get(:billing, "/api/checkout/#{"00000000-0000-4000-8000-0000000000ff"}", as: newbie.id)
  :ok
end)

IO.puts("social ↔ accounts + temps réel")
Smoke.check("conversations de lea (directes et groupe) enrichies avec les noms d'accounts", fn ->
  {:ok, %{"conversations" => convs}} = Client.get(:social, "/api/me/conversations", as: lea.id)
  true = convs != [] and Enum.any?(convs, &(&1["kind"] == "group"))
  true = Enum.all?(convs, fn c -> Enum.all?(c["members"], &is_binary(&1["user"]["display_name"])) end)
  :ok
end)
Smoke.check("message lea → hugo : {:new_message} LIVRÉ sur user:<hugo> (livraison par membre) via le cluster", fn ->
  {:ok, %{"conversation" => %{"id" => cid}}} = Client.post(:social, "/api/conversations", as: lea.id, json: %{user_id: hugo.id})
  :ok = Events.subscribe(Events.user(hugo.id))
  {:ok, %{"message" => %{"id" => mid}}} = Client.post(:social, "/api/conversations/#{cid}/messages", as: lea.id, json: %{body: "Smoke test: meet at the Grove?"})
  receive do
    {:new_message, %{"id" => ^mid, "conversation_id" => ^cid}} -> :ok
  after
    3_000 -> {:error, :no_event}
  end
end)
Smoke.check("centre de notifications : notification d'Hugo créée par social (sans le texte), puis lue avec la conversation", fn ->
  {:ok, %{"conversation" => %{"id" => cid}}} = Client.post(:social, "/api/conversations", as: lea.id, json: %{user_id: hugo.id})
  {:ok, %{"message" => _}} = Client.post(:social, "/api/conversations/#{cid}/messages", as: lea.id, json: %{body: "Smoke: the grove at nine"})

  receive do
    {:notifications_changed, id, _toast} when id == hugo.id -> :ok
  after
    5_000 -> raise "no notifications_changed event"
  end

  unread = fn ->
    {:ok, %{"entries" => entries}} = Client.get(:notifications, "/api/me/notifications", as: hugo.id, params: [filter: "unread"])
    Enum.filter(entries, &(&1["params"]["conversation_id"] == cid))
  end

  [%{"kind" => "message_received", "actor" => %{"display_name" => "Léa Moreau"}} = n] = unread.()
  false = inspect(n) =~ "grove at nine"
  {:ok, %{"unread" => count}} = Client.get(:notifications, "/api/me/notifications/unread-count", as: hugo.id)
  true = count >= 1
  :ok = Client.post(:social, "/api/conversations/#{cid}/read", as: hugo.id) |> elem(0)
  Enum.find_value(1..30, fn _ -> if unread.() == [], do: :ok, else: (Process.sleep(200) && nil) end) || {:error, :still_unread}
end)
sarah = Demo.user("sarah_lefevre")
ines = Demo.user("ines_petit")
# Un processus par topic, qui renvoie chaque événement étiqueté de son topic : on sait qui a reçu quoi.
watch = fn topic ->
  parent = self()

  spawn(fn ->
    :ok = Events.subscribe(topic)
    send(parent, {:watching, topic})
    Stream.repeatedly(fn -> receive(do: (msg -> send(parent, {topic, msg}))) end) |> Stream.run()
  end)

  receive do
    {:watching, ^topic} -> :ok
  end
end

Smoke.check("groupe lea + hugo + ines : livré à chaque membre, rien pour un non-membre ; membre retiré → 404", fn ->
  [orion_topic, samira_topic] = [Events.user(hugo.id), Events.user(sarah.id)]
  Enum.each([orion_topic, samira_topic], watch)
  {:ok, %{"conversation" => %{"id" => gid, "members" => [_, _, _]}}} =
    Client.post(:social, "/api/groups", as: lea.id, json: %{name: "Smoke circle", member_ids: [hugo.id, ines.id]})
  {:ok, %{"message" => %{"id" => mid}}} = Client.post(:social, "/api/conversations/#{gid}/messages", as: lea.id, json: %{body: "Group smoke"})
  receive do
    {^orion_topic, {:new_message, %{"id" => ^mid}}} -> :ok
  after
    3_000 -> raise "no event for hugo"
  end
  receive do
    {^samira_topic, {:new_message, %{"conversation_id" => ^gid}}} = leaked -> raise "delivered to a non-member: #{inspect(leaked)}"
  after
    300 -> :ok
  end
  {:ok, _} = Client.delete(:social, "/api/conversations/#{gid}/members/#{hugo.id}", as: lea.id)
  {:error, {:http, 404, _}} = Client.get(:social, "/api/conversations/#{gid}/messages", as: hugo.id)
  {:ok, _} = Client.post(:social, "/api/conversations/#{gid}/leave", as: lea.id)
  Client.post(:social, "/api/conversations/#{gid}/leave", as: ines.id)
end)
Smoke.check("permission de contact (route interne, appelée par multiplayer) : 403 explicite", fn ->
  {:error, {:http, 403, %{"error" => "not_friends"}}} =
    Client.get(:social, "/api/internal/can-contact", params: [from: lea.id, to: sarah.id, kind: "lobby_invite"])
  {:ok, %{"allowed" => true}} =
    Client.get(:social, "/api/internal/can-contact", params: [from: lea.id, to: hugo.id, kind: "lobby_invite"])
  :ok
end)
Smoke.check("non-membre (sarah) → 404 sur la conversation", fn ->
  {:ok, %{"conversations" => [c | _]}} = Client.get(:social, "/api/me/conversations", as: lea.id)
  {:error, {:http, 404, _}} = Client.get(:social, "/api/conversations/#{c["id"]}", as: Demo.user("sarah_lefevre").id)
  :ok
end)

if Process.get(:failed), do: (IO.puts("ÉCHEC"); System.halt(1)), else: IO.puts("TOUT OK")
