defmodule MysticWeb.Help do
  @moduledoc "Help center content and its server-side search."
  use Gettext, backend: MysticWeb.Gettext
  use MysticWeb, :verified_routes

  @max_query 100

  def max_query, do: @max_query

  @doc "`[{key, label, icon}]` in display order."
  def topics do
    [
      {"account", gettext("Account and login"), "hero-user-circle"},
      {"learning", gettext("Lessons and progress"), "hero-academic-cap"},
      {"membership", gettext("Membership and payments"), "hero-sparkles"},
      {"social", gettext("Friends, messages and community"), "hero-chat-bubble-left-right"},
      {"studio", gettext("Studio"), "hero-pencil-square"},
      {"privacy", gettext("Personal data"), "hero-lock-closed"},
      {"accessibility", gettext("Accessibility and display"), "hero-eye"},
      {"problems", gettext("Something doesn't work"), "hero-wrench-screwdriver"}
    ]
  end

  def topic_label(key) do
    case List.keyfind(topics(), key, 0) do
      {_, label, _} -> label
      nil -> key
    end
  end

  @doc "Every entry: `%{id, topic, question, answer, links: [{label, path}]}`."
  def entries do
    [
      entry(
        "create-account",
        "account",
        gettext("How do I create an account?"),
        gettext(
          "Choose « Join », enter your e-mail address, a username and a password of at least 12 characters, then open the confirmation link we e-mail you (it works for 7 days). You can log in once your address is confirmed."
        ),
        [{gettext("Create an account"), ~p"/register"}]
      ),
      entry(
        "confirmation-email",
        "account",
        gettext("I didn't receive the confirmation e-mail"),
        gettext(
          "Check your spam folder. On the login page, a correct password with an unconfirmed address offers to send a new link (3 per hour at most). An expired link explains it and offers a new one."
        ),
        [{gettext("Log in"), ~p"/login"}]
      ),
      entry(
        "forgot-password",
        "account",
        gettext("I forgot my password"),
        gettext(
          "Ask for a reset link: it works once, for 1 hour. Choosing a new password signs you out everywhere; two-factor authentication, if it is on, is still asked at the next login."
        ),
        [{gettext("Reset my password"), ~p"/forgot-password"}]
      ),
      entry(
        "two-factor",
        "account",
        gettext("How do I turn on two-factor authentication?"),
        gettext(
          "In Settings › Security, scan the QR code with an authenticator app and enter a code. Keep the 10 recovery codes shown once: each one replaces a code if you lose your phone. If you lose both, the team can't restore the access."
        ),
        [{gettext("Security settings"), ~p"/settings/security"}]
      ),
      entry(
        "session-ended",
        "account",
        gettext("Why was I sent back to the login page?"),
        gettext(
          "A session ends after 30 days without use, when you log out on another device or sign your other sessions out, and when your password changes. Log in again: you go back to the page you were on."
        ),
        [{gettext("Active sessions"), ~p"/settings/security"}]
      ),
      entry(
        "change-email",
        "account",
        gettext("How do I change my e-mail address?"),
        gettext(
          "In Settings › Account, with your password: a link is sent to the new address (valid 24 hours) and your current address is warned. Nothing changes until the link is opened while you are logged in."
        ),
        [{gettext("Account settings"), ~p"/settings/account"}]
      ),
      entry(
        "xp",
        "learning",
        gettext("How is XP counted?"),
        gettext(
          "Each lesson gives its XP once, the first time you complete it; replaying never adds more. Your level, streak, daily goal and last 7 days are on your dashboard."
        ),
        [{gettext("Dashboard"), ~p"/dashboard"}]
      ),
      entry(
        "formats",
        "learning",
        gettext("What kinds of lessons are there?"),
        gettext(
          "Stories, quizzes, small coding spells (a safe mini-language, nothing runs on your computer), videos with captions and a transcript, simulations and keyboard mini-games. Answers are checked by the server."
        ),
        [{gettext("Browse adventures"), ~p"/adventures"}]
      ),
      entry(
        "answer-refused",
        "learning",
        gettext("My answer was refused, but I think it is right"),
        gettext(
          "The feedback under the answer explains what was expected. If you still think the lesson is wrong, report it with the contact form (topic « Report a problem ») and name the adventure and the lesson."
        ),
        [{gettext("Report a problem"), ~p"/contact?#{[topic: "bug"]}"}]
      ),
      entry(
        "offline-lessons",
        "learning",
        gettext("Can I read lessons without a connection?"),
        gettext(
          "With a Premium or VIP membership, the stories and quizzes of Premium adventures can be kept on your device: choose « Make available offline » on the lesson page, then open them from the offline page, even without a connection. A copy stays %{days} days at most and never after the end of your paid period. Offline, your quiz answers and the stories you finish wait on the device — they are never marked right or wrong there: the server checks them when you're back online, they count on the day they are synchronized, and the same answer is never counted twice. If a lesson changed in the meantime, or your Premium access ended, the waiting answer is refused with the reason. A downloaded copy sits on the device unprotected: anyone using the device can read it, and a device that never reconnects keeps it until it expires. Logging out, another member logging in on the device and « Clear offline data » delete everything; the end of your Premium access deletes the copies.",
          days: MysticWeb.Offline.max_days()
        ),
        [
          {gettext("Offline lessons"), ~p"/settings/offline"},
          {gettext("Membership"), ~p"/membership"}
        ]
      ),
      entry(
        "recommendations",
        "learning",
        gettext("How are adventures recommended to me?"),
        gettext(
          "Your interests order the recommendations on your dashboard; your daily XP goal sets the progress bar of the day. Both can be changed at any time, or during the welcome tour."
        ),
        [
          {gettext("Choose my interests"), ~p"/settings/profile"},
          {gettext("Daily goal"), ~p"/settings/learning"}
        ]
      ),
      entry(
        "pay",
        "membership",
        gettext("Do I have to pay?"),
        gettext(
          "No: free adventures are open to every member. Premium adventures need a paid plan. On this demonstration, payment is simulated unless the operator configured Stripe test keys: no real money moves."
        ),
        [{gettext("Membership"), ~p"/membership"}]
      ),
      entry(
        "cancel",
        "membership",
        gettext("How do I cancel my membership?"),
        gettext(
          "From the membership page, at any time: your plan stays active until the end of the current period, and you can resume it until then."
        ),
        [{gettext("Membership"), ~p"/membership"}]
      ),
      entry(
        "access-ended",
        "membership",
        gettext("My Premium access ended"),
        gettext(
          "When a membership ends, premium lessons and VIP themes say so with the end date instead of failing silently: your progress is kept, and renewing opens them again."
        ),
        [{gettext("Renew my membership"), ~p"/membership"}]
      ),
      entry(
        "credits",
        "membership",
        gettext("What are AI credits?"),
        gettext(
          "Credits pay for studio generations: 20 a month with Free, 300 with Premium, 1,000 with VIP. They don't carry over to the next month; a failed generation is refunded once."
        ),
        [{gettext("My AI credits"), ~p"/studio/credits"}]
      ),
      entry(
        "who-messages",
        "social",
        gettext("Who can send me messages?"),
        gettext(
          "Only your friends, in private conversations or groups of up to 20 members. You decide who may send you a friend request, add you to a group or invite you to an activity."
        ),
        [{gettext("Privacy settings"), ~p"/settings/privacy"}]
      ),
      entry(
        "block-report",
        "social",
        gettext("How do I block or report someone?"),
        gettext(
          "In Friends, each member has « Block » and « Report »; in a conversation, « Report » sits next to the other person's messages. Blocking ends the friendship and stops messages; a report goes to the moderation team, which never reads your conversations — only the reported message."
        ),
        [{gettext("Friends"), ~p"/friends"}]
      ),
      entry(
        "encryption",
        "social",
        gettext("Are my messages encrypted?"),
        gettext(
          "They are private between their participants, but not end-to-end encrypted: the operator of the servers could technically read them."
        ),
        [{gettext("Privacy notice"), ~p"/legal/privacy"}]
      ),
      entry(
        "invitation-expired",
        "social",
        gettext("An invitation link to an activity doesn't work"),
        gettext(
          "Invitation links can expire, be revoked by the host or be used up, and an activity can be full or over: the page says which. Ask the host for a new link."
        ),
        [{gettext("Multiplayer"), ~p"/multiplayer"}]
      ),
      entry(
        "real-ai",
        "studio",
        gettext("Does the studio use a real AI?"),
        gettext(
          "Only if the operator configured an AI key. Without one, AI generation is unavailable in production; outside production, every output is labelled « DEMO MODE — not a real AI ». An external AI receives the brief you type; your drafts only if you and the project's owner turn on « Share my drafts with the AI »."
        ),
        [{gettext("Studio"), ~p"/studio"}]
      ),
      entry(
        "publish",
        "studio",
        gettext("How is a studio adventure published?"),
        gettext(
          "Automatic checks, your declarations, then a review by the staff: approved adventures are imported into the catalogue; otherwise the project goes back to draft with the reason."
        ),
        [{gettext("Studio"), ~p"/studio"}]
      ),
      entry(
        "export",
        "privacy",
        gettext("How do I get a copy of my data?"),
        gettext(
          "In Settings › Privacy & data, ask for an export with your password: one file gathers your data from every service (never other members' messages). It stays downloadable for 24 hours."
        ),
        [{gettext("Export my data"), ~p"/settings/data"}]
      ),
      entry(
        "delete-account",
        "privacy",
        gettext("How do I delete my account?"),
        gettext(
          "In Settings › Privacy & data, with your password and your username. The deletion happens after 30 days, and you can cancel it until then. What others see stays as « Deleted member »."
        ),
        [{gettext("Delete my account"), ~p"/settings/data"}]
      ),
      entry(
        "cookies",
        "privacy",
        gettext("Which cookies does MysticLore use?"),
        gettext(
          "Only what it needs to work: the session cookie, the language you chose, and two short-lived technical cookies. No analytics, advertising or third-party cookie, hence no consent banner."
        ),
        [{gettext("Cookies and browser storage"), ~p"/legal/cookies"}]
      ),
      entry(
        "profile-visibility",
        "privacy",
        gettext("Who can see my profile?"),
        gettext(
          "Your name, username and avatar always appear next to what you share. The rest (bio, pronouns, interests, academy record) follows your choice — everyone, members, friends or only you — with a preview."
        ),
        [{gettext("Privacy & data"), ~p"/settings/data"}]
      ),
      entry(
        "display",
        "accessibility",
        gettext("Can I make the text bigger or reduce animations?"),
        gettext(
          "Yes, in Settings › Accessibility: text up to 150 %, high contrast, reduced motion, underlined links and captions by default, applied on every page and every device you use."
        ),
        [{gettext("Accessibility settings"), ~p"/settings/accessibility"}]
      ),
      entry(
        "language",
        "accessibility",
        gettext("How do I change the language or the time zone?"),
        gettext(
          "Members choose them in Settings › Preferences (automatic follows your browser). Visitors choose the language at the bottom of every page."
        ),
        [{gettext("Preferences"), ~p"/settings/preferences"}]
      ),
      entry(
        "statement",
        "accessibility",
        gettext("Is MysticLore accessible?"),
        gettext(
          "We aim for WCAG 2.2 AA and check the layout, the targets and the contrast automatically, but there has been no external audit: the accessibility statement lists what was checked and the known limitations."
        ),
        [{gettext("Accessibility statement"), ~p"/legal/accessibility"}]
      ),
      entry(
        "unavailable",
        "problems",
        gettext("A part of the page says « Temporarily unavailable »"),
        gettext(
          "One of the services didn't answer; the rest of the page keeps working and nothing is invented in its place. « Try again » really reloads the page's data."
        ),
        []
      ),
      entry(
        "offline",
        "problems",
        gettext("The page says « You seem to be offline »"),
        gettext(
          "Your connection or the live connection to MysticLore was lost: until it is back, the buttons that save something are disabled, so nothing looks saved when it isn't. « Retry now » reconnects at once. Lessons you made available offline still work from the offline page: their answers wait on the device and are sent when the connection is back."
        ),
        [{gettext("Offline lessons"), ~p"/offline"}]
      ),
      entry(
        "report-problem",
        "problems",
        gettext("How do I report a problem or reach the team?"),
        gettext(
          "Use the contact form: choose a topic and describe what happened. You get an acknowledgement by e-mail, then the answer at the same address. We can't promise a response time."
        ),
        [{gettext("Contact us"), ~p"/contact"}]
      )
    ]
  end

  defp entry(id, topic, question, answer, links),
    do: %{id: id, topic: topic, question: question, answer: answer, links: links}

  @doc "The entries matching every word of `query` (accents and case ignored); all of them for a blank query."
  def search(query) do
    case words(query) do
      [] ->
        entries()

      words ->
        Enum.filter(entries(), fn e ->
          haystack = normalize(Enum.join([topic_label(e.topic), e.question, e.answer], " "))
          Enum.all?(words, &String.contains?(haystack, &1))
        end)
    end
  end

  @doc "The query as it is used: trimmed, 100 characters at most."
  def query(value) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, @max_query)

  def query(_value), do: ""

  defp words(query) do
    query
    |> query()
    |> normalize()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 2))
  end

  defp normalize(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
  end
end
