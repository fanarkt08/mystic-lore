defmodule MlAccounts.SupportEmail do
  @moduledoc """
  E-mails du support, en anglais ou en français. L'accusé de réception ne contient jamais le texte soumis.
  """
  import Swoosh.Email
  alias MlAccounts.SupportRequest

  def acknowledgement(%SupportRequest{} = request, address) do
    lang = request.locale

    body =
      t(
        lang,
        """
        Hello,

        We received your request (reference #{request.reference}, topic: #{topic(request.topic, "en")}).

        A member of the MysticLore team will answer you at this address. We can't promise a response time.

        For your security, this e-mail never repeats the content of your message. If you didn't write to
        MysticLore, you can ignore this e-mail.
        #{member_line(request, "en")}
        Help center: #{url("/help")}
        """,
        """
        Bonjour,

        Nous avons bien reçu votre demande (référence #{request.reference}, sujet : #{topic(request.topic, "fr")}).

        Un membre de l'équipe MysticLore vous répondra à cette adresse. Nous ne pouvons pas promettre de délai de
        réponse.

        Pour votre sécurité, cet e-mail ne reprend jamais le contenu de votre message. Si vous n'avez pas écrit à
        MysticLore, vous pouvez ignorer cet e-mail.
        #{member_line(request, "fr")}
        Centre d'aide : #{url("/help")}
        """
      )

    subject =
      t(
        lang,
        "We received your request #{request.reference}",
        "Nous avons bien reçu votre demande #{request.reference}"
      )

    base(address, subject) |> text_body(body)
  end

  def reply(%SupportRequest{} = request, reply, address) do
    lang = request.locale

    body =
      t(
        lang,
        """
        Hello,

        The MysticLore team answered your request #{request.reference} (topic: #{topic(request.topic, "en")}):

        #{reply.body}

        To write to us again, use the contact form and mention the reference #{request.reference}:
        #{url("/contact")}

        This e-mail doesn't repeat your original message.
        """,
        """
        Bonjour,

        L'équipe MysticLore a répondu à votre demande #{request.reference} (sujet : #{topic(request.topic, "fr")}) :

        #{reply.body}

        Pour nous écrire de nouveau, utilisez le formulaire de contact en indiquant la référence #{request.reference} :
        #{url("/contact")}

        Cet e-mail ne reprend pas votre message d'origine.
        """
      )

    subject =
      t(
        lang,
        "Reply to your request #{request.reference}",
        "Réponse à votre demande #{request.reference}"
      )

    base(address, subject) |> text_body(body)
  end

  defp member_line(%SupportRequest{user_id: nil}, _lang), do: ""

  defp member_line(_request, "fr"),
    do: "\nVous pouvez suivre vos demandes une fois connecté : #{url("/contact")}\n"

  defp member_line(_request, _lang),
    do: "\nYou can follow your requests once logged in: #{url("/contact")}\n"

  defp topic("account", "fr"), do: "Compte"
  defp topic("billing", "fr"), do: "Abonnement et paiements"
  defp topic("privacy", "fr"), do: "Données personnelles"
  defp topic("bug", "fr"), do: "Signaler un problème"
  defp topic(_other, "fr"), do: "Autre"
  defp topic("account", _), do: "Account"
  defp topic("billing", _), do: "Membership and payments"
  defp topic("privacy", _), do: "Personal data"
  defp topic("bug", _), do: "Report a problem"
  defp topic(_other, _), do: "Other"

  defp t("fr", _en, fr), do: fr
  defp t(_lang, en, _fr), do: en

  defp base(address, subject) do
    new()
    |> to(address)
    |> from(Application.fetch_env!(:accounts, :mail_from))
    |> subject(subject)
  end

  defp url(path), do: Application.fetch_env!(:accounts, :web_url) <> path
end
