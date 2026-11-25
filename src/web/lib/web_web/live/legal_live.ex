defmodule MysticWeb.LegalLive do
  @moduledoc "Provisional legal pages, open to everyone."
  use MysticWeb, :live_view
  import MysticWeb.LegalComponents
  alias MysticWeb.Legal

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"document" => doc}, _uri, socket) do
    if not Legal.document?(doc), do: raise(MysticWeb.NotFoundError)

    {:noreply,
     socket
     |> assign(document: doc, page_title: Legal.title(doc))
     |> load(doc)}
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, assign(socket, document: nil, page_title: gettext("Legal information"))}

  defp load(socket, "privacy") do
    payments =
      case Api.get(nil, :billing, "/api/plans") do
        {:ok, %{"mode" => mode}} when mode in ~w(stripe local disabled) -> mode
        _ -> :unavailable
      end

    ai =
      if socket.assigns.current_user do
        case Api.get(socket, :studio, "/api/ai") do
          {:ok, %{"provider" => _} = info} -> info
          _ -> :unavailable
        end
      else
        :visitor
      end

    assign(socket, payments: payments, ai: ai)
  end

  defp load(socket, _doc), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      unread={@unread}
      notifications={@notifications}
      current_path={@current_path}
    >
      <div class="legal-layout">
        <aside class="legal-aside">
          <.legal_nav current={@document} />
        </aside>
        <article id={"legal-#{@document || "index"}"} class="legal-article min-w-0">
          <.page_header
            eyebrow={gettext("Legal information")}
            title={if @document, do: Legal.title(@document), else: gettext("Legal information")}
          >
            {if @document,
              do: Legal.summary(@document),
              else: gettext("The provisional documents of MysticLore and who runs the service.")}
          </.page_header>
          <.legal_banner document={@document} />
          <%= case @document do %>
            <% nil -> %>
              <.index_page />
            <% "privacy" -> %>
              <.privacy_page payments={@payments} ai={@ai} current_user={@current_user} />
            <% "terms" -> %>
              <.terms_page />
            <% "cookies" -> %>
              <.cookies_page />
            <% "accessibility" -> %>
              <.accessibility_page />
          <% end %>
        </article>
      </div>
    </Layouts.app>
    """
  end

  ## /legal

  defp index_page(assigns) do
    ~H"""
    <ul id="legal-documents" class="grid gap-4 md:grid-cols-2">
      <li :for={doc <- Legal.documents()} class="card space-y-2">
        <h2 class="flex items-center gap-2 text-2xl">
          <.icon name={Legal.icon(doc)} class="size-5 text-magic" />
          <.link navigate={~p"/legal/#{doc}"} class="card-link" id={"legal-doc-#{doc}"}>
            {Legal.title(doc)}
          </.link>
        </h2>
        <p class="text-sm text-muted">{Legal.summary(doc)}</p>
        <p class="text-xs text-muted">
          {gettext("Version %{version} · last updated %{date}",
            version: elem(Legal.version(doc), 0),
            date: date(elem(Legal.version(doc), 1))
          )}
        </p>
      </li>
    </ul>
    <.legal_section id="operator" title={gettext("Who runs MysticLore")}>
      <p>
        {gettext(
          "MysticLore is a demonstration project. Before it is put into production, the operator must complete the information below; until then, these documents are not a valid legal notice."
        )}
      </p>
      <.operator_identity />
    </.legal_section>
    <.legal_section id="questions" title={gettext("Questions")}>
      <p>
        {gettext("For any question about these documents or your data, use the contact form.")}
        <.link navigate={~p"/contact?#{[topic: "privacy"]}"} class="link" id="legal-contact">
          {gettext("Contact us")}
        </.link>
      </p>
    </.legal_section>
    """
  end

  ## /legal/privacy

  attr :payments, :any, required: true
  attr :ai, :any, required: true
  attr :current_user, :map, default: nil

  defp privacy_page(assigns) do
    ~H"""
    <.legal_section id="controller" title={gettext("1. Who is responsible for your data")}>
      <p>
        {gettext(
          "The operator of this site is responsible for the data described here (the « controller »). This version does not name it:"
        )}
      </p>
      <.operator_identity />
      <p>
        {gettext(
          "MysticLore is a demonstration: its demo members, adventures and payments are fictional. If you create an account, what you enter (e-mail address, messages, notes…) is real data, handled as described below."
        )}
      </p>
    </.legal_section>

    <.legal_section
      id="data"
      title={gettext("2. What each part of MysticLore keeps, and for how long")}
    >
      <p>
        {gettext(
          "MysticLore is made of separate services, each with its own database. This table lists, service by service, what is kept about a member and the retention coded in this version."
        )}
      </p>
      <.legal_table
        id="retention"
        caption={gettext("Data and retention per service")}
        rows={retention()}
      >
        <:col :let={row} label={gettext("Service")}>{row.service}</:col>
        <:col :let={row} label={gettext("Data")}>{row.data}</:col>
        <:col :let={row} label={gettext("Kept for")}>{row.kept}</:col>
      </.legal_table>
      <p>
        {gettext(
          "When an account is deleted (after a 30-day grace period during which you can cancel), personal data is erased in every service; what other members can still see (messages, forum posts, game history) stays under the name « Deleted member »; invoices and the AI credit ledger are kept without personal data for accounting."
        )}
        <.link navigate={~p"/settings/data"} class="link">{gettext("Delete my account")}</.link>
      </p>
      <p>
        {gettext(
          "Server logs (requests) are kept by the host; their retention depends on the hosting:"
        )}
        <.placeholder id="logs-retention">{gettext("log retention period")}</.placeholder>
        {gettext(
          "The code keeps passwords, codes, tokens, message texts and moderation reasons out of the logs, and never logs the addresses that carry a token (confirmation, password reset, e-mail change)."
        )}
      </p>
      <p>
        {gettext("The audit log of staff actions has no automatic deletion in this version:")}
        <.placeholder id="audit-retention">
          {gettext("retention period of the audit log")}
        </.placeholder>
      </p>
    </.legal_section>

    <.legal_section id="purposes" title={gettext("3. Why the data is used")}>
      <ul class="legal-list">
        <li>
          {gettext(
            "To provide the service you ask for: your account, lessons, progress, friends, messages, forum, multiplayer, studio, membership."
          )}
        </li>
        <li>
          {gettext(
            "Security: login protection, two-factor authentication, active sessions, rate limits, antivirus scanning of attachments when configured."
          )}
        </li>
        <li>
          {gettext(
            "Moderation: reports, sanctions and appeals; every staff action is written in an audit log."
          )}
        </li>
        <li>{gettext("Billing: subscriptions, invoices and AI credits.")}</li>
        <li>{gettext("Answering your requests sent with the contact form.")}</li>
      </ul>
      <p>
        {gettext(
          "There is no advertising, no tracking for marketing and no sale of data. Legal bases:"
        )}
        <.placeholder id="legal-bases">
          {gettext("legal basis of each purpose, to be determined with a lawyer")}
        </.placeholder>
      </p>
    </.legal_section>

    <.legal_section id="processors" title={gettext("4. Who else may receive data")}>
      <p>
        {gettext(
          "Only if the operator configures them. « On this server » says what THIS server is set to do right now."
        )}
      </p>
      <div id="processors-list" class="legal-cards">
        <article id="processor-stripe" class="card space-y-2">
          <h3 class="text-xl">{gettext("Payments: Stripe")}</h3>
          <p class="text-sm">
            {gettext(
              "Used only if the operator sets Stripe keys (test keys in this demo). MysticLore sends Stripe your member identifier and the chosen plan; you type your card and billing e-mail on Stripe's own page: they never reach MysticLore."
            )}
          </p>
          <p class="legal-status" id="processor-stripe-status">
            <span class="font-medium">{gettext("On this server:")}</span>
            {payments_status(@payments)}
          </p>
        </article>
        <article id="processor-ai" class="card space-y-2">
          <h3 class="text-xl">{gettext("AI generation in the studio: Anthropic")}</h3>
          <p class="text-sm">
            {gettext(
              "Used only if the operator sets an Anthropic API key; otherwise nothing leaves the server (in production, AI generation is then unavailable; elsewhere, a local demo generator labelled « DEMO MODE » is used). With an external provider, it receives the brief you type for a generation; your drafts (project brief, outline, lesson) are added only if you AND the project owner turned on « Share my drafts with the AI ». Private messages are never sent."
            )}
          </p>
          <p class="legal-status" id="processor-ai-status">
            <span class="font-medium">{gettext("On this server:")}</span>
            {ai_status(@ai)}
          </p>
        </article>
        <article id="processor-email" class="card space-y-2">
          <h3 class="text-xl">{gettext("E-mail delivery")}</h3>
          <p class="text-sm">
            {gettext(
              "No e-mail provider is configured in this version: in development, e-mails stay in a local mailbox on the server and are not sent. Before production, the operator must configure one and name it here:"
            )}
            <.placeholder id="email-provider">{gettext("e-mail delivery provider")}</.placeholder>
          </p>
        </article>
        <article id="processor-antivirus" class="card space-y-2">
          <h3 class="text-xl">{gettext("Antivirus for attachments: ClamAV")}</h3>
          <p class="text-sm">
            {gettext(
              "If the operator configures a ClamAV daemon (clamd), each file attached to a message is sent to it before being stored. ClamAV is software run by the operator, not a company receiving your files (unless the operator chooses a hosted one). Without it, files are accepted and shown as « not scanned »."
            )}
          </p>
        </article>
        <article id="processor-host" class="card space-y-2">
          <h3 class="text-xl">{gettext("Hosting")}</h3>
          <p class="text-sm">
            {gettext("The servers and databases are run by:")}
            <.placeholder id="hosting-provider">
              {gettext("hosting provider and location of the data")}
            </.placeholder>
          </p>
        </article>
      </div>
      <p>
        {gettext(
          "Fonts are served by this site itself; no analytics, advertising, social-network or font service receives anything when you browse."
        )}
      </p>
    </.legal_section>

    <.legal_section id="rights" title={gettext("5. Your rights")}>
      <ul class="legal-list">
        <li>
          {gettext("Access and portability: download all your data (one file, every service).")}
          <.link navigate={~p"/settings/data"} class="link" id="rights-export">{gettext(
            "Export my data"
          )}</.link>
        </li>
        <li>
          {gettext("Erasure: delete your account (30-day grace period, cancellable).")}
          <.link navigate={~p"/settings/data"} class="link" id="rights-delete">{gettext(
            "Delete my account"
          )}</.link>
        </li>
        <li>
          {gettext("Rectification: change your profile, e-mail address and preferences.")}
          <.link navigate={~p"/settings/profile"} class="link">{gettext("Settings")}</.link>
        </li>
        <li>
          {gettext("Optional e-mails and who may contact you: in your settings.")}
          <.link navigate={~p"/settings/notifications"} class="link">{gettext("Notifications")}</.link>
          · <.link navigate={~p"/settings/privacy"} class="link">{gettext("Privacy")}</.link>
        </li>
        <li>
          {gettext("Any other request (objection, restriction, question):")}
          <.link navigate={~p"/contact?#{[topic: "privacy"]}"} class="link" id="rights-contact">
            {gettext("contact form, topic « Personal data »")}
          </.link>
          <.placeholder id="dpo-contact">{gettext("or the data protection contact")}</.placeholder>
        </li>
        <li>
          {gettext("You may also complain to a data protection authority:")}
          <.placeholder id="supervisory-authority">{gettext("competent authority")}</.placeholder>
        </li>
      </ul>
      <p class="text-sm text-muted">
        {gettext("We don't promise a response time for requests sent with the contact form.")}
      </p>
    </.legal_section>

    <.legal_section id="security" title={gettext("6. How the data is protected")}>
      <ul class="legal-list">
        <li>
          {gettext(
            "Passwords are stored hashed (bcrypt), never in clear; two-factor authentication is available, its secrets encrypted at rest."
          )}
        </li>
        <li>
          {gettext(
            "The IP address of a session is stored truncated (the last part removed) and the device description is shortened."
          )}
        </li>
        <li>
          {gettext(
            "Uploaded images are cleaned of their metadata (location, camera) before being stored."
          )}
        </li>
        <li>
          {gettext(
            "Messages are private between their participants but NOT end-to-end encrypted: the operator can technically read them. Staff tools never open a conversation; only the snapshot of a reported message can be read, with a written reason that is audited."
          )}
        </li>
        <li>
          {gettext(
            "Staff actions (moderation, roles, support) are written in an append-only audit log."
          )}
        </li>
        <li>
          {gettext(
            "Offline lesson copies are kept by your browser on your device as they are: they are not encrypted there and not protected against copying."
          )}
        </li>
      </ul>
      <p class="text-sm text-muted">
        {gettext(
          "These measures are tested automatically; they are not certified, and automated tests don't replace a security audit."
        )}
      </p>
    </.legal_section>
    """
  end

  defp retention do
    [
      %{
        service: gettext("Account"),
        data:
          gettext(
            "E-mail address, username, display name, password hash, profile (bio, pronouns, interests, cover, avatar), preferences, two-factor settings, active sessions (shortened device, truncated IP), sanctions and appeals, support requests."
          ),
        kept:
          gettext(
            "Until the account is deleted. Sessions: 30 days without use. Links sent by e-mail: 7 days (confirmation), 1 hour (password), 24 hours (new e-mail). Data exports: 24 hours. Support requests: 180 days after they are closed (365 days at most without activity)."
          )
      },
      %{
        service: gettext("Learning"),
        data:
          gettext(
            "Adventures followed, lesson progress, notes, drafts, XP, badges, and the receipt of each answer synchronized from an offline lesson (its result, so that it is never counted twice)."
          ),
        kept: gettext("Until the account is deleted.")
      },
      %{
        service: gettext("Membership"),
        data:
          gettext(
            "Plan, subscription status, payment sessions, invoices (amount, period), AI credit ledger."
          ),
        kept:
          gettext(
            "Until the account is deleted; invoices and the credit ledger are then kept without personal data."
          )
      },
      %{
        service: gettext("Friends and messages"),
        data:
          gettext(
            "Friends, requests, blocks, privacy settings, conversations, messages, attachments, reports."
          ),
        kept:
          gettext(
            "Until the account is deleted; your messages then stay visible to the other participants as « Deleted member », your attachments' files are erased."
          )
      },
      %{
        service: gettext("Multiplayer and forum"),
        data:
          gettext(
            "Activities, chat messages, games, invitations; discussions, replies, votes, follows, reports."
          ),
        kept:
          gettext(
            "Until the account is deleted; contributions seen by others then stay as « Deleted member »."
          )
      },
      %{
        service: gettext("Studio"),
        data:
          gettext(
            "Projects, versions, images, collaborators, AI settings, AI requests and results."
          ),
        kept:
          gettext(
            "Until the account is deleted; shared or published projects are kept without their owner."
          )
      },
      %{
        service: gettext("Notifications"),
        data:
          gettext(
            "Notifications received (identifiers and public titles only, never a message text), channel choices, quiet hours and their time zone."
          ),
        kept: gettext("90 days, 500 per member at most; erased when the account is deleted.")
      },
      %{
        service: gettext("Your device (offline lessons)"),
        data:
          gettext(
            "Only if you download lessons: copies of premium lessons (text and questions, never the answers), your member identifier, download and expiry dates, answers waiting for synchronization. Kept by your browser, not by our servers."
          ),
        kept:
          gettext(
            "%{days} days at most per copy and never after the end of your paid period. Everything is deleted at logout, when another member logs in on the device, or from your settings; when your Premium access ends, the copies are deleted (answers still waiting stay, and are refused with the reason if the access is still over when they are synchronized). A device that never reconnects keeps its copies until they expire.",
            days: MysticWeb.Offline.max_days()
          )
      }
    ]
  end

  defp payments_status("stripe"),
    do: gettext("Stripe keys are configured: checkout goes through Stripe.")

  defp payments_status("local"),
    do:
      gettext(
        "Payments are simulated locally (demo mode): nothing is sent to Stripe, no money moves."
      )

  defp payments_status("disabled"), do: gettext("Payments are disabled.")
  defp payments_status(_), do: gettext("Unknown right now (the billing service doesn't answer).")

  defp ai_status(:visitor),
    do: gettext("Shown to signed-in members (with their own « share my drafts » choice).")

  defp ai_status(%{"demo" => true}),
    do: gettext("Local demo generator: no AI provider receives anything.")

  defp ai_status(%{"external" => true, "configured" => true} = info) do
    if info["share_drafts_with_ai"],
      do:
        gettext(
          "Anthropic is configured. You turned « Share my drafts with the AI » on: your drafts can be sent with your requests."
        ),
      else:
        gettext(
          "Anthropic is configured. « Share my drafts with the AI » is off for you: only the brief you type is sent."
        )
  end

  defp ai_status(%{"configured" => false}),
    do: gettext("No AI key is configured: AI generation is unavailable, nothing is sent.")

  defp ai_status(_), do: gettext("Unknown right now (the studio service doesn't answer).")

  ## /legal/terms

  defp terms_page(assigns) do
    ~H"""
    <.legal_section id="purpose" title={gettext("1. What MysticLore is")}>
      <p>
        {gettext(
          "MysticLore is a demonstration of an online academy: adventures, members, prices and payments shown here are fictional. These terms describe how the service works in this version; the operator must complete and validate them before any production use."
        )}
      </p>
      <.operator_identity />
    </.legal_section>
    <.legal_section id="account" title={gettext("2. Your account")}>
      <ul class="legal-list">
        <li>
          {gettext(
            "An account needs a valid e-mail address, confirmed by a link, and a password of at least 12 characters. Keep it secret; two-factor authentication is available."
          )}
        </li>
        <li>
          {gettext(
            "You can export your data or delete your account at any time from your settings; a deletion happens after 30 days and can be cancelled until then."
          )}
        </li>
        <li>
          {gettext("Minimum age and parental consent:")}
          <.placeholder id="terms-age">{gettext("rules to be set by the operator")}</.placeholder>
        </li>
      </ul>
    </.legal_section>
    <.legal_section id="conduct" title={gettext("3. Conduct")}>
      <p>
        {gettext(
          "No harassment, spam or inappropriate content in messages, the forum, activity chats or studio projects. Any member can report a member or a message, and block a member."
        )}
      </p>
      <p>
        {gettext(
          "The moderation team can remove content, send a warning or restrict an account for a limited time (no messages, forum posts or chat during it). Each decision states its reason and can be appealed once; the appeal is decided by another staff member."
        )}
        <.link navigate={~p"/account/sanctions"} class="link">{gettext("Account standing")}</.link>
      </p>
    </.legal_section>
    <.legal_section id="content" title={gettext("4. What you create")}>
      <p>
        {gettext(
          "Your messages, forum posts and studio projects remain visible to the people they were shared with, also after your account is deleted (as « Deleted member »). A studio adventure is published in the catalogue only after automatic checks, your declarations and a review by the staff."
        )}
      </p>
      <p>
        {gettext("Rights on published content:")}
        <.placeholder id="terms-licence">
          {gettext("licence granted to the operator and to other members")}
        </.placeholder>
      </p>
      <p>
        {gettext(
          "Texts proposed by the AI in the studio are suggestions to review: you decide what you keep. Without an AI key, AI generation is unavailable in production; outside production, a demo generator labelled « DEMO MODE » is used."
        )}
      </p>
    </.legal_section>
    <.legal_section id="membership" title={gettext("5. Memberships and payments")}>
      <ul class="legal-list">
        <li>{gettext("Free, Premium and VIP plans; the prices shown are demonstration values.")}</li>
        <li>
          {gettext(
            "In demo payment mode, payment is simulated: no card is asked and no money moves. With Stripe test keys, only Stripe's test cards work."
          )}
        </li>
        <li>
          {gettext(
            "A plan changes only once the payment provider's signed confirmation is received. A cancellation takes effect at the end of the current period; AI credits are granted each month and don't carry over."
          )}
        </li>
        <li>
          {gettext("Withdrawal, refunds and prices including taxes:")}
          <.placeholder id="terms-refunds">{gettext("rules to be set by the operator")}</.placeholder>
        </li>
      </ul>
    </.legal_section>
    <.legal_section id="availability" title={gettext("6. Availability and liability")}>
      <p>
        {gettext(
          "This demonstration is provided without any guarantee of availability. When a service doesn't answer, the page says so instead of showing made-up data."
        )}
      </p>
      <p>
        {gettext("Liability, applicable law and competent courts:")}
        <.placeholder id="terms-law">{gettext("to be written with a lawyer")}</.placeholder>
      </p>
    </.legal_section>
    <.legal_section id="related" title={gettext("7. Related documents")}>
      <p>
        <.link navigate={~p"/legal/privacy"} class="link">{gettext("Privacy notice")}</.link>
        ·
        <.link navigate={~p"/legal/cookies"} class="link">{gettext("Cookies and browser storage")}</.link>
        · <.link navigate={~p"/contact"} class="link">{gettext("Contact us")}</.link>
      </p>
    </.legal_section>
    """
  end

  ## /legal/cookies

  defp cookies_page(assigns) do
    ~H"""
    <.legal_section id="no-banner" title={gettext("Why there is no consent banner")}>
      <p>
        {gettext(
          "MysticLore only uses the cookies and browser storage it needs to work (and the language cookie you set yourself). There is no analytics, advertising, social-network or third-party cookie, and fonts are served by this site. Strictly necessary storage doesn't need consent, so there is nothing to accept or refuse — and no fake banner."
        )}
      </p>
      <p>
        {gettext(
          "If the operator ever adds non-essential cookies (for example audience measurement), a real consent choice must be added before they are set."
        )}
      </p>
    </.legal_section>
    <.legal_section id="cookies" title={gettext("Cookies")}>
      <.legal_table
        id="cookie-table"
        caption={gettext("Cookies set by this site")}
        rows={Legal.cookies()}
      >
        <:col :let={c} label={gettext("Name")}><code>{c.name}</code></:col>
        <:col :let={c} label={gettext("Set by")}>{c.by}</:col>
        <:col :let={c} label={gettext("Purpose")}>{c.purpose}</:col>
        <:col :let={c} label={gettext("Lifetime")}>{c.duration}</:col>
        <:col :let={c} label={gettext("Type")}>{c.kind}</:col>
      </.legal_table>
    </.legal_section>
    <.legal_section id="storage" title={gettext("Browser storage")}>
      <p>
        {gettext(
          "For visitors, MysticLore's own scripts store nothing in the browser. The framework that runs the live pages (Phoenix LiveView) uses the first entries below; the last three serve the offline lessons and exist only on a device where a member chose « Make available offline »."
        )}
      </p>
      <.legal_table
        id="storage-table"
        caption={gettext("Browser storage entries")}
        rows={Legal.storage()}
      >
        <:col :let={s} label={gettext("Entry")}><code>{s.name}</code></:col>
        <:col :let={s} label={gettext("Storage")}><code>{s.where}</code></:col>
        <:col :let={s} label={gettext("Purpose")}>{s.purpose}</:col>
        <:col :let={s} label={gettext("Lifetime")}>{s.duration}</:col>
      </.legal_table>
      <p>
        {gettext(
          "Your browser's time zone is sent when a live page connects, to show dates in your time; it is not stored (except as the time zone of your quiet hours, when you save them)."
        )}
      </p>
    </.legal_section>
    <.legal_section id="offline-storage" title={gettext("Offline lessons on this device")}>
      <p>
        {gettext(
          "A lesson made available offline is a copy kept by your browser on this device. The copy, the service worker and its cache are created only when you choose « Make available offline », because they are needed for what you asked (reading without a connection): like the other entries, they are treated as necessary, without a consent banner — to be confirmed by a lawyer, like the rest of this provisional text."
        )}
      </p>
      <ul class="legal-list">
        <li>
          {gettext(
            "The copy is not protected against copying: anyone using this device, or able to read its storage, can read it."
          )}
        </li>
        <li>
          {gettext(
            "A device that never connects again keeps its copies until they expire (%{days} days at most after the download, never after the end of the paid period); an expired copy is no longer shown and is deleted as soon as a MysticLore page opens on that device.",
            days: MysticWeb.Offline.max_days()
          )}
        </li>
        <li>
          {gettext(
            "Answers given offline stay on the device until they are synchronized: they are sent only for the member who gave them, and checked by the server."
          )}
        </li>
      </ul>
      <p>
        <.link navigate={~p"/settings/offline"} class="link" id="cookies-offline-settings">
          {gettext("Offline lessons on this device")}
        </.link>
      </p>
    </.legal_section>
    <.legal_section id="control" title={gettext("How to remove them")}>
      <p>
        {gettext(
          "Logging out ends your session and asks the browser to delete this site's storage (offline lessons, answers waiting for synchronization, the service worker and its files); your browser's settings delete cookies and site data at any time (you'll then need to log in again). « Clear offline data » in the settings deletes all of it (offline lessons, answers waiting for synchronization, the service worker and its files) without logging out."
        )}
      </p>
    </.legal_section>
    <.legal_section id="cookie-operator" title={gettext("Who is responsible")}>
      <p>
        {gettext("The operator of this site:")}
        <.placeholder id="cookies-operator">{gettext("name of the operator")}</.placeholder>
        <.link navigate={~p"/contact?#{[topic: "privacy"]}"} class="link">{gettext("Contact us")}</.link>
      </p>
    </.legal_section>
    """
  end

  ## /legal/accessibility

  defp accessibility_page(assigns) do
    ~H"""
    <.legal_section id="status" title={gettext("Status")}>
      <p>
        {gettext(
          "Our goal is the WCAG 2.2 level AA. MysticLore has NOT been audited by an external body: we don't claim any conformity level. This statement lists what was built and checked automatically, and what wasn't."
        )}
      </p>
    </.legal_section>
    <.legal_section id="measures" title={gettext("What is in place")}>
      <ul class="legal-list">
        <li>
          {gettext(
            "Structured headings, labelled fields with their errors next to them, a « skip to content » link, a visible focus ring."
          )}
        </li>
        <li>
          {gettext(
            "Controls of at least 44 pixels, polite announcements of live changes (new messages, saves, notifications)."
          )}
        </li>
        <li>
          {gettext(
            "Settings applied on every page: reduced motion, high contrast, text up to 150 %, underlined links, captions on by default."
          )}
        </li>
        <li>
          {gettext(
            "Video lessons with captions (English and French) and a transcript; simulations described in a table; mini-games playable with the keyboard; charts doubled by a table."
          )}
        </li>
        <li>
          {gettext(
            "The pages are laid out from 320 pixels wide without horizontal scrolling, in English and in French (checked automatically, see below)."
          )}
        </li>
        <li>
          {gettext(
            "Keyboard use, checked on the main pages: every control can be reached with Tab in the order of the page, dialogs close with Escape and give the focus back, and no action needs dragging."
          )}
        </li>
      </ul>
    </.legal_section>
    <.legal_section id="checks" title={gettext("What was checked, and how")}>
      <ul class="legal-list">
        <li>
          {gettext(
            "Automatically, in Chrome, with the axe-core tool (rules of WCAG 2.0, 2.1 and 2.2, levels A and AA): the pages and their main states (forms with errors, dialogs, menus, offline banner, lesson player of each format), in the dark and light themes, with high contrast, in English and in French. The contrast of text on gradients is measured on the displayed page."
          )}
        </li>
        <li>
          {gettext(
            "By scripts, in Chrome: keyboard-only paths (log in, lesson, message, forum topic, settings, offline page), visible focus never fully hidden, target size, reduced motion, text spacing, zoom at 200 %, pasting allowed when logging in, help link at the same place, status messages announced."
          )}
        </li>
        <li>
          {gettext(
            "No horizontal scrolling and no control smaller than 44 pixels on the main pages at 320, 390, 768, 1024 and 1440 pixels; pages at 390 pixels with the text at 150 %."
          )}
        </li>
        <li>{gettext("Contrast of the text computed for every theme (at least 4.5:1).")}</li>
      </ul>
      <p class="text-sm text-muted">
        {gettext(
          "These automated checks don't prove conformity. Not done: tests with screen readers (NVDA, JAWS, VoiceOver) and other assistive technologies, an external audit, tests in other browsers than Chrome."
        )}
      </p>
    </.legal_section>
    <.legal_section id="limits" title={gettext("Known limitations")}>
      <ul class="legal-list">
        <li>
          {gettext(
            "The contrast of non-text elements (field borders) is only guaranteed in high contrast mode."
          )}
        </li>
        <li>
          {gettext(
            "Cover illustrations stay dark in every theme; some small labels (mobile bar, 7-day chart) don't grow beyond 12 pixels."
          )}
        </li>
        <li>
          {gettext(
            "With the text alone enlarged to 200 % (without zooming the page), a few lessons with wide content need horizontal scrolling."
          )}
        </li>
        <li>{gettext("The French translation has not been reviewed by a native speaker.")}</li>
      </ul>
    </.legal_section>
    <.legal_section id="feedback" title={gettext("Tell us about a barrier")}>
      <p>
        {gettext(
          "If something blocks you, tell us with the contact form (topic « Report a problem »)."
        )}
        <.link navigate={~p"/contact?#{[topic: "bug"]}"} class="link" id="accessibility-contact">
          {gettext("Contact us")}
        </.link>
      </p>
      <p>
        {gettext("Remedies if you get no satisfactory answer:")}
        <.placeholder id="accessibility-authority">
          {gettext("competent authority or ombudsman")}
        </.placeholder>
      </p>
    </.legal_section>
    """
  end
end
