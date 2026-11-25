defmodule MysticWeb.Notifications do
  @moduledoc """
  Builds the text and the link of each notification from `kind` and `params`.
  Links are local paths built from validated identifiers, so no open redirect is possible.
  """
  use Gettext, backend: MysticWeb.Gettext
  use MysticWeb, :verified_routes
  alias MysticWeb.Api

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @slug ~r/\A[a-z0-9][a-z0-9\-]{0,79}\z/

  @categories ~w(security account billing messages friends community multiplayer studio learning)

  def categories, do: @categories

  ## API (le membre de la page ; le service autorise tout lui-même)

  @doc "Nombre de non-lues, `nil` si le centre ne répond pas."
  def unread_count(who) do
    case Api.get(who, :notifications, "/api/me/notifications/unread-count") do
      {:ok, %{"unread" => n}} when is_integer(n) -> n
      _ -> nil
    end
  end

  @doc "Une notification du membre (`nil` si elle n'existe pas ou si le centre ne répond pas)."
  def fetch(who, id) do
    case Api.get(who, :notifications, "/api/me/notifications/:id", path_params: [id: id]) do
      {:ok, %{"notification" => %{"id" => _} = n}} -> n
      _ -> nil
    end
  end

  @doc "Titre et motif des décisions du studio, relus chez studio pour le membre (accès vérifié par studio)."
  def enrich(who, notifications) when is_list(notifications) do
    projects =
      notifications
      |> Enum.filter(&(&1["category"] == "studio"))
      |> Enum.map(& &1["params"]["project_id"])
      |> Enum.filter(&uuid?/1)
      |> Enum.uniq()
      |> Map.new(fn id ->
        case Api.get(who, :studio, "/api/projects/:id", path_params: [id: id]) do
          {:ok, %{"project" => %{"title" => title} = p}} ->
            {id, %{"title" => title, "reason" => get_in(p, ["review", "reason"])}}

          _ ->
            {id, nil}
        end
      end)

    Enum.map(notifications, fn n ->
      case projects[n["params"]["project_id"]] do
        nil -> n
        project -> Map.put(n, "project", project)
      end
    end)
  end

  ## Libellés

  def category_label("security"), do: gettext("Security")
  def category_label("account"), do: gettext("Account")
  def category_label("billing"), do: gettext("Membership and payments")
  def category_label("messages"), do: gettext("Messages")
  def category_label("friends"), do: gettext("Friends and groups")
  def category_label("community"), do: gettext("Community")
  def category_label("multiplayer"), do: gettext("Multiplayer")
  def category_label("studio"), do: gettext("Studio")
  def category_label("learning"), do: gettext("Learning")
  def category_label(other), do: to_string(other)

  def category_hint("security"),
    do:
      gettext(
        "Password, e-mail address, two-factor authentication, signed-out sessions. Always on, in the app and by e-mail."
      )

  def category_hint("account"),
    do:
      gettext(
        "Sanctions, appeal decisions, data exports, replies to your support requests. Always shown here; moderation decisions and support replies are always e-mailed."
      )

  def category_hint("billing"),
    do:
      gettext(
        "Membership activated or ending, payment problems. Payment problems and the end of a membership are always sent, because they affect your access."
      )

  def category_hint("messages"), do: gettext("New messages in your conversations and groups.")

  def category_hint("friends"),
    do: gettext("Friend requests, accepted requests, being added to a group.")

  def category_hint("community"), do: gettext("Replies in the discussions you follow.")
  def category_hint("multiplayer"), do: gettext("Invitations to an activity.")
  def category_hint("studio"), do: gettext("Review decisions on your studio projects.")
  def category_hint("learning"), do: gettext("Badges you earn.")
  def category_hint(_), do: nil

  def icon(%{"category" => category}), do: category_icon(category)

  defp category_icon("security"), do: "hero-shield-check"
  defp category_icon("account"), do: "hero-user-circle"
  defp category_icon("billing"), do: "hero-sparkles"
  defp category_icon("messages"), do: "hero-chat-bubble-left-right"
  defp category_icon("friends"), do: "hero-user-group"
  defp category_icon("community"), do: "hero-chat-bubble-bottom-center-text"
  defp category_icon("multiplayer"), do: "hero-puzzle-piece"
  defp category_icon("studio"), do: "hero-pencil-square"
  defp category_icon("learning"), do: "hero-trophy"
  defp category_icon(_), do: "hero-bell"

  ## Phrase (gettext), à partir de kind et params, jamais d'un texte stocké

  @doc "La phrase traduite d'une notification."
  def text(%{"kind" => kind} = n) do
    params = n["params"] || %{}
    count = if is_integer(n["count"]) and n["count"] > 0, do: n["count"], else: 1
    sentence(kind, params, count, actor_name(n), n)
  end

  def text(_n), do: gettext("You have a new notification")

  @doc "Nom de l'acteur (identité d'accounts ; « A member » si elle n'a pas pu être lue)."
  def actor_name(%{"actor" => %{} = actor}),
    do: MysticWeb.MysticComponents.member_name(actor) || gettext("A member")

  def actor_name(_n), do: gettext("A member")

  defp sentence("message_received", %{"conversation_kind" => "group"} = p, count, name, _n) do
    group = text_param(p["group_name"]) || gettext("a group")

    if count > 1,
      do:
        gettext("%{count} new messages in “%{group}”, the latest from %{name}",
          count: count,
          group: group,
          name: name
        ),
      else: gettext("%{name} wrote in “%{group}”", name: name, group: group)
  end

  defp sentence("message_received", _p, count, name, _n),
    do:
      ngettext("%{name} sent you a message", "%{name} sent you %{count} messages", count,
        name: name
      )

  defp sentence("friend_request_received", _p, _count, name, _n),
    do: gettext("%{name} sent you a friend request", name: name)

  defp sentence("friend_request_accepted", _p, _count, name, _n),
    do: gettext("%{name} accepted your friend request", name: name)

  defp sentence("group_added", p, _count, name, _n),
    do:
      gettext("%{name} added you to the group “%{group}”",
        name: name,
        group: text_param(p["group_name"]) || gettext("a group")
      )

  defp sentence("community_reply", p, count, name, _n) do
    title = text_param(p["title"]) || gettext("a discussion")

    if count > 1,
      do: gettext("%{count} new replies in “%{title}”", count: count, title: title),
      else: gettext("%{name} replied in “%{title}”", name: name, title: title)
  end

  defp sentence("lobby_invite", p, _count, name, _n),
    do:
      gettext("%{name} invited you to the activity “%{title}”",
        name: name,
        title: text_param(p["lobby_title"]) || gettext("an activity")
      )

  defp sentence("review_approved", _p, _count, _name, %{"project" => %{"title" => title}})
       when is_binary(title),
       do: gettext("Your studio project “%{title}” was approved", title: title)

  defp sentence("review_approved", _p, _count, _name, _n),
    do: gettext("Your studio project was approved")

  defp sentence("review_rejected", _p, _count, _name, %{"project" => %{"title" => title}})
       when is_binary(title),
       do: gettext("Your studio project “%{title}” was sent back to draft", title: title)

  defp sentence("review_rejected", _p, _count, _name, _n),
    do: gettext("Your studio project was sent back to draft")

  defp sentence("badge_earned", p, _count, _name, _n),
    do:
      gettext("You earned the badge “%{badge}”",
        badge: text_param(p["badge_name"]) || gettext("a badge")
      )

  defp sentence("subscription_activated", p, _count, _name, _n),
    do: gettext("Your %{plan} membership is active", plan: plan(p["plan"]))

  defp sentence("payment_failed", p, _count, _name, _n),
    do:
      gettext(
        "A payment for your %{plan} membership failed: update your payment method to keep your access",
        plan: plan(p["plan"])
      )

  defp sentence("cancellation_scheduled", %{"period_end" => at} = p, _count, _name, _n)
       when is_binary(at),
       do:
         gettext("Your %{plan} membership will end on %{date}",
           plan: plan(p["plan"]),
           date: MysticWeb.Format.date(at)
         )

  defp sentence("cancellation_scheduled", p, _count, _name, _n),
    do:
      gettext("Your %{plan} membership will end at the end of the period", plan: plan(p["plan"]))

  defp sentence("subscription_ended", p, _count, _name, _n),
    do: gettext("Your %{plan} membership has ended", plan: plan(p["plan"]))

  defp sentence("password_changed", %{"method" => "reset"}, _count, _name, _n),
    do: gettext("Your password was reset")

  defp sentence("password_changed", _p, _count, _name, _n),
    do: gettext("Your password was changed")

  defp sentence("email_changed", _p, _count, _name, _n),
    do: gettext("Your e-mail address was changed")

  defp sentence("two_factor_enabled", _p, _count, _name, _n),
    do: gettext("Two-factor authentication was turned on")

  defp sentence("two_factor_disabled", _p, _count, _name, _n),
    do: gettext("Two-factor authentication was turned off")

  defp sentence("recovery_codes_regenerated", _p, _count, _name, _n),
    do: gettext("New recovery codes were generated: the previous ones no longer work")

  defp sentence("sessions_revoked", p, _count, _name, _n) do
    n = if is_integer(p["count"]) and p["count"] > 0, do: p["count"], else: 1

    ngettext(
      "A session of your account was signed out",
      "%{count} sessions of your account were signed out",
      n
    )
  end

  defp sentence(
         "sanction_issued",
         %{"sanction_kind" => "restriction", "ends_at" => at},
         _c,
         _n,
         _x
       )
       when is_binary(at),
       do:
         gettext("Your account is restricted until %{date}", date: MysticWeb.Format.datetime(at))

  defp sentence("sanction_issued", %{"sanction_kind" => "restriction"}, _count, _name, _n),
    do: gettext("Your account is restricted by the moderation team")

  defp sentence("sanction_issued", _p, _count, _name, _n),
    do: gettext("You received a warning from the moderation team")

  defp sentence("sanction_lifted", _p, _count, _name, _n),
    do: gettext("A sanction on your account was lifted")

  defp sentence("appeal_decided", %{"outcome" => "accepted"}, _count, _name, _n),
    do: gettext("Your appeal was accepted: the sanction is lifted")

  defp sentence("appeal_decided", _p, _count, _name, _n),
    do: gettext("Your appeal was rejected")

  defp sentence("export_ready", _p, _count, _name, _n),
    do: gettext("Your data export is ready to download")

  defp sentence("export_failed", _p, _count, _name, _n),
    do: gettext("Your data export could not be completed")

  defp sentence("support_replied", _p, _count, _name, _n),
    do: gettext("The team answered your support request (the reply was also e-mailed)")

  defp sentence(_kind, _p, _count, _name, _n), do: gettext("You have a new notification")

  @doc "Motif d'un retour en brouillon (relu chez studio), à montrer sous la phrase."
  def detail(%{"kind" => "review_rejected", "project" => %{"reason" => reason}})
      when is_binary(reason),
      do: reason

  def detail(_n), do: nil

  defp plan("vip"), do: "VIP"
  defp plan(_premium), do: "Premium"

  defp text_param(value) when is_binary(value) and value != "", do: value
  defp text_param(_value), do: nil

  ## Lien, calculé ici et jamais stocké

  @doc "Chemin local de la cible d'une notification."
  def path(%{"kind" => kind, "params" => params}) when is_map(params), do: target(kind, params)
  def path(%{"kind" => kind}), do: target(kind, %{})
  def path(_n), do: ~p"/notifications"

  defp target(kind, %{"conversation_id" => id}) when kind in ~w(message_received group_added),
    do: if(uuid?(id), do: ~p"/messages/#{id}", else: ~p"/messages")

  defp target(kind, _p) when kind in ~w(message_received group_added), do: ~p"/messages"

  defp target(kind, _p) when kind in ~w(friend_request_received friend_request_accepted),
    do: ~p"/friends"

  defp target("community_reply", %{"slug" => slug}) when is_binary(slug) do
    if Regex.match?(@slug, slug), do: ~p"/community/discussions/#{slug}", else: ~p"/community"
  end

  defp target("community_reply", _p), do: ~p"/community"
  defp target("lobby_invite", _p), do: ~p"/multiplayer"

  defp target(kind, %{"project_id" => id}) when kind in ~w(review_approved review_rejected),
    do: if(uuid?(id), do: ~p"/studio/#{id}", else: ~p"/studio")

  defp target(kind, _p) when kind in ~w(review_approved review_rejected), do: ~p"/studio"
  defp target("badge_earned", _p), do: ~p"/achievements"

  defp target(kind, _p)
       when kind in ~w(subscription_activated payment_failed cancellation_scheduled subscription_ended),
       do: ~p"/membership"

  defp target(kind, _p) when kind in ~w(password_changed email_changed), do: ~p"/settings/account"

  defp target(kind, _p)
       when kind in ~w(two_factor_enabled two_factor_disabled recovery_codes_regenerated sessions_revoked),
       do: ~p"/settings/security"

  defp target(kind, _p) when kind in ~w(sanction_issued sanction_lifted appeal_decided),
    do: ~p"/account/sanctions"

  defp target(kind, _p) when kind in ~w(export_ready export_failed), do: ~p"/settings/data"

  # the request on the contact page (anchor of the member's request list)
  defp target("support_replied", %{"request_id" => id}),
    do: if(uuid?(id), do: ~p"/contact" <> "#request-#{id}", else: ~p"/contact")

  defp target("support_replied", _p), do: ~p"/contact"
  defp target(_kind, _p), do: ~p"/notifications"

  defp uuid?(id), do: is_binary(id) and Regex.match?(@uuid, id)
end
