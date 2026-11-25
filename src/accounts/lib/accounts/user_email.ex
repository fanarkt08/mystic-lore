defmodule MlAccounts.UserEmail do
  @moduledoc "E-mails envoyés aux membres. Les liens pointent vers le service `web` (`WEB_URL`)."
  import Swoosh.Email

  def confirmation(user, token) do
    base(user.display_name, user.email, "Confirm your MysticLore account")
    |> text_body("""
    Hi #{user.display_name},

    Welcome to MysticLore! Please confirm your email address by opening this link
    (valid for 7 days):

    #{url("/confirm/#{token}")}

    If you did not create a MysticLore account, you can ignore this email.
    """)
  end

  def password_reset(user, token) do
    base(user.display_name, user.email, "Reset your MysticLore password")
    |> text_body("""
    Hi #{user.display_name},

    Someone (hopefully you) asked to reset the password of your MysticLore account.
    Open this link to choose a new password (valid for 1 hour, usable once):

    #{url("/reset-password/#{token}")}

    Resetting your password signs you out everywhere. If two-factor authentication is on,
    it will still be required at your next login.

    If you did not ask for this, you can ignore this email: your password will not change.
    """)
  end

  def email_change_confirmation(user, new_email, token) do
    base(user.display_name, new_email, "Confirm your new MysticLore email address")
    |> text_body("""
    Hi #{user.display_name},

    You asked to use this address for your MysticLore account. Open this link while
    logged in to confirm the change (valid for 24 hours, usable once):

    #{url("/settings/confirm-email/#{token}")}

    If you did not ask for this, you can ignore this email: nothing will change.
    """)
  end

  def email_change_notice(user, new_email) do
    base(user.display_name, user.email, "Your MysticLore email address is about to change")
    |> text_body("""
    Hi #{user.display_name},

    A change of the email address of your MysticLore account to #{mask(new_email)}
    was requested. It will only happen once the link sent to that address is opened.

    If this was not you, change your password now from Settings, then sign out
    your other sessions: someone may know your current password.
    """)
  end

  def deletion_scheduled(user, at) do
    date = Calendar.strftime(at, "%B %-d, %Y at %H:%M UTC")

    base(user.display_name, user.email, "Your MysticLore account will be deleted")
    |> text_body("""
    Hi #{user.display_name},

    You asked to delete your MysticLore account. It will be deleted on #{date}.
    All your sessions have been signed out.

    Until then you can change your mind: log in and choose "Cancel deletion" in Settings:

    #{url("/settings")}

    On that date your personal data (profile, progress, notes, XP, badges, friends,
    studio drafts, AI settings…) is erased. Your messages, forum posts and game history
    are kept under the name "Deleted member". Your subscription is cancelled; invoices
    and the credit ledger are kept without personal data, as accounting law requires.

    If you did not ask for this, log in now, cancel the deletion and change your password.
    """)
  end

  def sanction_issued(user, %{kind: "warning"} = sanction) do
    base(user.display_name, user.email, "You received a warning on MysticLore")
    |> text_body("""
    Hi #{user.display_name},

    The moderation team sent you a warning:

    #{sanction.reason}

    Your account is not restricted. If you think this is a mistake, you can appeal
    (explain why) from your account standing page:

    #{url("/account/sanctions")}
    """)
  end

  def sanction_issued(user, sanction) do
    until = Calendar.strftime(sanction.ends_at, "%B %-d, %Y at %H:%M UTC")

    base(user.display_name, user.email, "Your MysticLore account is restricted")
    |> text_body("""
    Hi #{user.display_name},

    The moderation team restricted your account until #{until}:

    #{sanction.reason}

    Until then you can still read, learn and play, but you can't send private messages,
    post in the forum or write in multiplayer lobby chats.

    If you think this is a mistake, you can appeal (explain why) from your account standing page:

    #{url("/account/sanctions")}
    """)
  end

  def sanction_lifted(user, sanction) do
    what = if sanction.kind == "warning", do: "warning", else: "restriction"

    base(user.display_name, user.email, "A sanction on your MysticLore account was lifted")
    |> text_body("""
    Hi #{user.display_name},

    The #{what} on your account was lifted by the moderation team.

    Details: #{url("/account/sanctions")}
    """)
  end

  def appeal_decided(user, appeal) do
    {subject, outcome} =
      if appeal.status == "accepted",
        do: {"Your appeal was accepted", "accepted: the sanction is lifted."},
        else: {"Your appeal was rejected", "rejected: the sanction stays in place."}

    base(user.display_name, user.email, subject)
    |> text_body("""
    Hi #{user.display_name},

    A member of the staff who did not issue the sanction reviewed your appeal. It was #{outcome}

    #{appeal.decision_reason}

    Details: #{url("/account/sanctions")}
    """)
  end

  defp base(name, address, subject) do
    new()
    |> to({name, address})
    |> from(Application.fetch_env!(:accounts, :mail_from))
    |> subject(subject)
  end

  defp url(path), do: Application.fetch_env!(:accounts, :web_url) <> path

  # « l•••@example.test » : l'ancienne adresse ne voit pas la nouvelle en entier.
  defp mask(email) do
    [local, domain] = String.split(email, "@", parts: 2)
    String.first(local) <> "•••@" <> domain
  end
end
