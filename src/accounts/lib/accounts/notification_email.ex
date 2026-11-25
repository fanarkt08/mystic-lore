defmodule MlAccounts.NotificationEmail do
  @moduledoc """
  Rédige les e-mails demandés par le centre de notifications, à partir de modèles en liste blanche.
  Aucun contenu privé n'y figure, et le lien est calculé ici à partir d'identifiants validés.
  """
  import Swoosh.Email
  alias MlAccounts.User

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @slug ~r/\A[a-z0-9][a-z0-9\-]{0,79}\z/
  @mandatory ~w(password_changed two_factor_enabled two_factor_disabled recovery_codes_regenerated
                sessions_revoked payment_failed subscription_ended)

  def locale(%User{preferences: %{language: lang}}) when lang in ~w(en fr), do: lang
  def locale(_user), do: "en"

  @doc "Construit l'e-mail d'une demande du centre pour `user`."
  def build(%User{} = user, %{"kind" => "digest", "items" => items} = request, names)
      when is_list(items) and items != [] do
    lang = locale(user)

    lines =
      Enum.map(items, fn item ->
        with %{"kind" => kind} when is_binary(kind) <- item,
             {:ok, %{subject: sentence}} <- item(kind, item, names, lang) do
          {:ok, "• " <> sentence}
        else
          _ -> :error
        end
      end)

    if Enum.all?(lines, &match?({:ok, _}, &1)) do
      total = max(as_count(request["total"]), length(items))
      more = total - length(items)
      text = Enum.map_join(lines, "\n", &elem(&1, 1))

      text =
        if more > 0,
          do: text <> "\n" <> t(lang, "…and %{n} more.", "… et %{n} autres.", n: more),
          else: text

      {:ok,
       compose(user, lang,
         subject:
           if(total == 1,
             do:
               t(
                 lang,
                 "While your quiet hours were on: 1 notification",
                 "Pendant vos heures calmes : 1 notification"
               ),
             else:
               t(
                 lang,
                 "While your quiet hours were on: %{n} notifications",
                 "Pendant vos heures calmes : %{n} notifications",
                 n: total
               )
           ),
         body: [
           t(
             lang,
             "Here is what happened during your quiet hours:",
             "Voici ce qui s'est passé pendant vos heures calmes :"
           ),
           text
         ],
         action:
           {t(lang, "See all your notifications:", "Voir toutes vos notifications :"),
            "/notifications"},
         mandatory: false
       )}
    else
      {:error, :invalid}
    end
  end

  def build(%User{} = user, %{"kind" => kind} = request, names) when is_binary(kind) do
    lang = locale(user)

    case item(kind, request, names, lang) do
      {:ok, %{subject: subject, body: body, action: action}} ->
        {:ok,
         compose(user, lang,
           subject: subject,
           body: [subject <> "."] ++ body,
           action: action,
           mandatory: kind in @mandatory
         )}

      :error ->
        {:error, :invalid}
    end
  end

  def build(_user, _request, _names), do: {:error, :invalid}

  @doc "Identifiants d'acteurs cités par la demande (pour lire leurs noms en une requête)."
  def actor_ids(%{"items" => items}) when is_list(items),
    do: items |> Enum.map(&actor_id/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  def actor_ids(request), do: List.wrap(actor_id(request))

  defp actor_id(%{"actor_id" => id}) when is_binary(id),
    do: if(Regex.match?(@uuid, id), do: id)

  defp actor_id(_request), do: nil

  ## Modèles (liste blanche)

  defp item(kind, request, names, lang) do
    params = if is_map(request["params"]), do: request["params"], else: %{}
    count = as_count(request["count"])
    name = names[actor_id(request)] || t(lang, "A member", "Un membre")
    template(kind, params, count, name, lang)
  end

  defp template("password_changed", params, _count, _name, lang) do
    subject =
      if params["method"] == "reset",
        do:
          t(
            lang,
            "Your MysticLore password was reset",
            "Le mot de passe de votre compte MysticLore a été réinitialisé"
          ),
        else:
          t(
            lang,
            "Your MysticLore password was changed",
            "Le mot de passe de votre compte MysticLore a été modifié"
          )

    ok(
      subject,
      [not_you(lang)],
      {t(lang, "Your security settings:", "Vos réglages de sécurité :"), "/settings/security"}
    )
  end

  defp template("two_factor_enabled", _params, _count, _name, lang) do
    ok(
      t(
        lang,
        "Two-factor authentication was turned on",
        "L'authentification à deux facteurs a été activée"
      ),
      [
        t(
          lang,
          "Keep your recovery codes in a safe place.",
          "Gardez vos codes de récupération en lieu sûr."
        ),
        not_you(lang)
      ],
      {t(lang, "Your security settings:", "Vos réglages de sécurité :"), "/settings/security"}
    )
  end

  defp template("two_factor_disabled", _params, _count, _name, lang) do
    ok(
      t(
        lang,
        "Two-factor authentication was turned off",
        "L'authentification à deux facteurs a été désactivée"
      ),
      [not_you(lang)],
      {t(lang, "Your security settings:", "Vos réglages de sécurité :"), "/settings/security"}
    )
  end

  defp template("recovery_codes_regenerated", _params, _count, _name, lang) do
    ok(
      t(
        lang,
        "New recovery codes were generated",
        "De nouveaux codes de récupération ont été générés"
      ),
      [
        t(lang, "The previous codes no longer work.", "Les anciens codes ne fonctionnent plus."),
        not_you(lang)
      ],
      {t(lang, "Your security settings:", "Vos réglages de sécurité :"), "/settings/security"}
    )
  end

  defp template("sessions_revoked", _params, _count, _name, lang) do
    ok(
      t(
        lang,
        "Sessions of your account were signed out",
        "Des sessions de votre compte ont été déconnectées"
      ),
      [not_you(lang)],
      {t(lang, "Your active sessions:", "Vos sessions actives :"), "/settings/security"}
    )
  end

  defp template("subscription_activated", %{"plan" => plan}, _count, _name, lang)
       when plan in ~w(premium vip) do
    ok(
      t(lang, "Your %{plan} membership is active", "Votre abonnement %{plan} est actif",
        plan: plan(plan)
      ),
      [],
      {t(lang, "Your membership:", "Votre abonnement :"), "/membership"}
    )
  end

  defp template("payment_failed", %{"plan" => plan}, _count, _name, lang)
       when plan in ~w(premium vip) do
    ok(
      t(
        lang,
        "A payment for your %{plan} membership failed",
        "Un paiement de votre abonnement %{plan} a échoué",
        plan: plan(plan)
      ),
      [
        t(
          lang,
          "Update your payment method to keep your access.",
          "Mettez à jour votre moyen de paiement pour garder votre accès."
        )
      ],
      {t(lang, "Your membership:", "Votre abonnement :"), "/membership"}
    )
  end

  defp template("cancellation_scheduled", %{"plan" => plan} = params, _count, _name, lang)
       when plan in ~w(premium vip) do
    subject =
      case date(params["period_end"], lang) do
        nil ->
          t(lang, "Your %{plan} membership will end", "Votre abonnement %{plan} va prendre fin",
            plan: plan(plan)
          )

        date ->
          t(
            lang,
            "Your %{plan} membership will end on %{date}",
            "Votre abonnement %{plan} prendra fin le %{date}",
            plan: plan(plan),
            date: date
          )
      end

    ok(
      subject,
      [
        t(
          lang,
          "You keep your access until then, and you can resume it from the membership page.",
          "Vous gardez votre accès jusque-là, et vous pouvez le reprendre depuis la page d'abonnement."
        )
      ],
      {t(lang, "Your membership:", "Votre abonnement :"), "/membership"}
    )
  end

  defp template("subscription_ended", %{"plan" => plan}, _count, _name, lang)
       when plan in ~w(premium vip) do
    ok(
      t(lang, "Your %{plan} membership has ended", "Votre abonnement %{plan} a pris fin",
        plan: plan(plan)
      ),
      [],
      {t(lang, "Your membership:", "Votre abonnement :"), "/membership"}
    )
  end

  defp template("message_received", %{"conversation_id" => id} = params, count, name, lang) do
    if uuid?(id) do
      subject =
        case {params["conversation_kind"], text(params["group_name"])} do
          {"group", group} when is_binary(group) ->
            t(lang, "%{name} wrote in “%{group}”", "%{name} a écrit dans « %{group} »",
              name: name,
              group: group
            )

          _direct when count > 1 ->
            t(
              lang,
              "%{name} sent you %{count} messages",
              "%{name} vous a envoyé %{count} messages",
              name: name,
              count: count
            )

          _direct ->
            t(lang, "%{name} sent you a message", "%{name} vous a envoyé un message", name: name)
        end

      ok(
        subject,
        [],
        {t(lang, "Open the conversation to read it:", "Ouvrez la conversation pour le lire :"),
         "/messages/#{id}"}
      )
    else
      :error
    end
  end

  defp template("friend_request_received", _params, _count, name, lang) do
    ok(
      t(lang, "%{name} sent you a friend request", "%{name} vous a envoyé une demande d'ami",
        name: name
      ),
      [],
      {t(lang, "Answer it:", "Répondre :"), "/friends"}
    )
  end

  defp template("friend_request_accepted", _params, _count, name, lang) do
    ok(
      t(lang, "%{name} accepted your friend request", "%{name} a accepté votre demande d'ami",
        name: name
      ),
      [],
      {t(lang, "Your friends:", "Vos amis :"), "/friends"}
    )
  end

  defp template("group_added", %{"conversation_id" => id} = params, _count, name, lang) do
    with true <- uuid?(id),
         group when is_binary(group) <- text(params["group_name"]) do
      ok(
        t(
          lang,
          "%{name} added you to the group “%{group}”",
          "%{name} vous a ajouté au groupe « %{group} »",
          name: name,
          group: group
        ),
        [],
        {t(lang, "Open the group:", "Ouvrir le groupe :"), "/messages/#{id}"}
      )
    else
      _ -> :error
    end
  end

  defp template("community_reply", %{"slug" => slug} = params, count, name, lang) do
    with true <- is_binary(slug) and Regex.match?(@slug, slug),
         title when is_binary(title) <- text(params["title"]) do
      subject =
        if count > 1,
          do:
            t(
              lang,
              "%{count} new replies in “%{title}”",
              "%{count} nouvelles réponses dans « %{title} »",
              count: count,
              title: title
            ),
          else:
            t(lang, "%{name} replied in “%{title}”", "%{name} a répondu dans « %{title} »",
              name: name,
              title: title
            )

      ok(
        subject,
        [],
        {t(lang, "Read the discussion:", "Lire la discussion :"),
         "/community/discussions/#{slug}"}
      )
    else
      _ -> :error
    end
  end

  defp template("lobby_invite", params, _count, name, lang) do
    case text(params["lobby_title"]) do
      title when is_binary(title) ->
        ok(
          t(lang, "%{name} invited you to “%{title}”", "%{name} vous invite à « %{title} »",
            name: name,
            title: title
          ),
          [],
          {t(lang, "Your invitations:", "Vos invitations :"), "/multiplayer"}
        )

      nil ->
        :error
    end
  end

  defp template(kind, %{"project_id" => id}, _count, _name, lang)
       when kind in ~w(review_approved review_rejected) do
    if uuid?(id) do
      {subject, body} =
        if kind == "review_approved",
          do:
            {t(lang, "Your studio project was approved", "Votre projet du studio a été approuvé"),
             []},
          else:
            {t(
               lang,
               "Your studio project was sent back to draft",
               "Votre projet du studio est revenu en brouillon"
             ),
             [
               t(
                 lang,
                 "Open it in the studio to read the reviewer's reason.",
                 "Ouvrez-le dans le studio pour lire le motif de la relecture."
               )
             ]}

      ok(subject, body, {t(lang, "Your project:", "Votre projet :"), "/studio/#{id}"})
    else
      :error
    end
  end

  defp template("badge_earned", params, _count, _name, lang) do
    case text(params["badge_name"]) do
      badge when is_binary(badge) ->
        ok(
          t(lang, "You earned the badge “%{badge}”", "Vous avez obtenu le badge « %{badge} »",
            badge: badge
          ),
          [],
          {t(lang, "Your achievements:", "Vos succès :"), "/achievements"}
        )

      nil ->
        :error
    end
  end

  defp template(_kind, _params, _count, _name, _lang), do: :error

  defp ok(subject, body, action), do: {:ok, %{subject: subject, body: body, action: action}}

  defp not_you(lang),
    do:
      t(
        lang,
        "If this wasn't you, reset your password right away (%{url}) and check your active sessions.",
        "Si ce n'était pas vous, réinitialisez tout de suite votre mot de passe (%{url}) et vérifiez vos sessions actives.",
        url: url("/forgot-password")
      )

  ## Mise en forme

  defp compose(user, lang, opts) do
    {label, path} = opts[:action]

    footer =
      if opts[:mandatory],
        do:
          t(
            lang,
            "This e-mail about your account's security or access is always sent. Your notification settings: %{url}",
            "Cet e-mail sur la sécurité ou l'accès de votre compte est toujours envoyé. Vos réglages de notifications : %{url}",
            url: url("/settings/notifications")
          ),
        else:
          t(
            lang,
            "You receive this e-mail because of your notification settings: %{url}",
            "Vous recevez cet e-mail selon vos réglages de notifications : %{url}",
            url: url("/settings/notifications")
          )

    paragraphs =
      [t(lang, "Hi %{name},", "Bonjour %{name},", name: user.display_name)] ++
        opts[:body] ++ ["#{label}\n#{url(path)}", "—\n" <> footer]

    new()
    |> to({user.display_name, user.email})
    |> from(Application.fetch_env!(:accounts, :mail_from))
    |> subject(opts[:subject])
    |> text_body(Enum.join(paragraphs, "\n\n") <> "\n")
  end

  defp t(lang, en, fr, bindings \\ []) do
    template = if lang == "fr", do: fr, else: en

    Enum.reduce(bindings, template, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp plan("premium"), do: "Premium"
  defp plan("vip"), do: "VIP"

  defp date(iso, lang) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} ->
        if lang == "fr",
          do: "#{dt.day}/#{String.pad_leading("#{dt.month}", 2, "0")}/#{dt.year}",
          else: Calendar.strftime(dt, "%B %-d, %Y")

      _ ->
        nil
    end
  end

  defp date(_iso, _lang), do: nil

  # titres publics transmis par le centre : texte brut, sans caractère de contrôle, borné
  defp text(value) when is_binary(value) do
    text =
      value
      |> String.replace(~r/[\p{Cc}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u, " ")
      |> String.trim()

    if text != "" and String.length(text) <= 140, do: text
  end

  defp text(_value), do: nil

  defp uuid?(id), do: is_binary(id) and Regex.match?(@uuid, id)

  defp as_count(n) when is_integer(n) and n > 0, do: min(n, 10_000)
  defp as_count(_n), do: 1

  defp url(path), do: Application.fetch_env!(:accounts, :web_url) <> path
end
