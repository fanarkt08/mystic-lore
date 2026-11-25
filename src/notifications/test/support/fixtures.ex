defmodule MlNotifications.Fixtures do
  @moduledoc "Données de test et faux accounts qui rapportent au test chaque e-mail demandé."
  alias MlNotifications.{Inbox, Preferences}

  def uuid, do: Ecto.UUID.generate()

  @doc "Demande de création valide pour `kind` (sa catégorie et ses paramètres requis), modifiable par `attrs`."
  def attrs(kind, user_id, attrs \\ %{}) do
    base =
      case kind do
        "message_received" ->
          conversation = Map.get(attrs, "conversation_id", uuid())

          %{
            "category" => "messages",
            "actor_id" => uuid(),
            "params" => %{"conversation_id" => conversation, "conversation_kind" => "direct"},
            "dedupe_key" => "conversation:#{conversation}"
          }

        "friend_request_received" ->
          %{"category" => "friends", "actor_id" => uuid(), "params" => %{"request_id" => uuid()}}

        "community_reply" ->
          %{
            "category" => "community",
            "actor_id" => uuid(),
            "params" => %{
              "slug" => "why-range-abc12345",
              "title" => "Why does range(3) stop at 2?"
            }
          }

        "lobby_invite" ->
          %{
            "category" => "multiplayer",
            "actor_id" => uuid(),
            "params" => %{
              "invite_id" => uuid(),
              "lobby_id" => uuid(),
              "lobby_title" => "Rune Relay"
            }
          }

        "badge_earned" ->
          %{
            "category" => "learning",
            "params" => %{"badge_slug" => "first-spark", "badge_name" => "Première étincelle"}
          }

        "review_approved" ->
          %{"category" => "studio", "params" => %{"project_id" => uuid()}}

        "payment_failed" ->
          %{"category" => "billing", "params" => %{"plan" => "premium"}}

        "subscription_activated" ->
          %{"category" => "billing", "params" => %{"plan" => "premium"}}

        "password_changed" ->
          %{"category" => "security", "params" => %{"method" => "settings"}}

        "email_changed" ->
          %{"category" => "security", "params" => %{}}

        "sanction_issued" ->
          %{
            "category" => "account",
            "params" => %{"sanction_id" => uuid(), "sanction_kind" => "warning"}
          }

        "support_replied" ->
          %{"category" => "account", "params" => %{"request_id" => uuid()}}
      end

    base
    |> Map.put_new("dedupe_key", "#{kind}:#{uuid()}")
    |> Map.merge(%{"user_id" => user_id, "kind" => kind})
    |> Map.merge(Map.delete(attrs, "conversation_id"))
  end

  @doc "Producteur de chaque catégorie (le `svc` autorisé)."
  def producer("messages"), do: "social"
  def producer("friends"), do: "social"
  def producer("security"), do: "accounts"
  def producer("account"), do: "accounts"
  def producer(category), do: category

  @doc "Crée par le vrai chemin (`Inbox.create/3`) → le résultat."
  def create!(attrs, now \\ DateTime.utc_now()) do
    {:ok, result} = Inbox.create(producer(attrs["category"]), attrs, now)
    result
  end

  def settings!(user_id, attrs, now \\ DateTime.utc_now()) do
    {:ok, setting} = Preferences.update(user_id, attrs, now)
    setting
  end

  def fake_accounts(email_response \\ {200, %{"status" => "sent"}}) do
    test = self()

    Req.Test.stub(MlShared.Client, fn
      %Plug.Conn{method: "GET", request_path: "/api/users"} = conn ->
        ids = String.split(conn.query_params["ids"] || "", ",", trim: true)
        Req.Test.json(conn, %{"users" => Enum.map(ids, &identity/1)})

      %Plug.Conn{method: "POST", request_path: "/api/internal/users/" <> rest} = conn ->
        [user_id, "notification-email"] = String.split(rest, "/")
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test, {:email_requested, user_id, Jason.decode!(raw)})

        case email_response do
          :unavailable ->
            Req.Test.transport_error(conn, :econnrefused)

          {status, body} ->
            conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
        end
    end)
  end

  def identity(id) do
    short = String.slice(id, 0, 8)

    %{
      "id" => id,
      "username" => "user_#{short}",
      "display_name" => "User #{short}",
      "avatar" => nil
    }
  end
end
