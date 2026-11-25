defmodule MysticWeb.ContactLive do
  @moduledoc """
  Contact form for visitors and members, with a trap field for robots and a limit per IP address.
  """
  use MysticWeb, :live_view
  alias MysticWeb.RateLimit

  @topics ~w(account billing privacy bug other)

  def topics, do: @topics

  def topic_label("account"), do: gettext("Account")
  def topic_label("billing"), do: gettext("Membership and payments")
  def topic_label("privacy"), do: gettext("Personal data")
  def topic_label("bug"), do: gettext("Report a problem")
  def topic_label(_other), do: gettext("Other")

  # contexte : statut d'une demande (accords du français : « Reçue », « Fermée »), distinct des autres « Received »
  def status_label("open"), do: pgettext("support request status", "Received")
  def status_label("answered"), do: pgettext("support request status", "Answered")
  def status_label("closed"), do: pgettext("support request status", "Closed")
  def status_label(other), do: to_string(other)

  @impl true
  def mount(params, _session, socket) do
    ip =
      if connected?(socket) do
        case get_connect_info(socket, :peer_data) do
          %{address: address} -> address
          _ -> nil
        end
      end

    {:ok,
     socket
     |> assign(page_title: gettext("Contact us"), sent: nil, error: nil)
     |> assign(form: contact_form(%{"topic" => topic(params["topic"])}))
     |> put_private(:client_ip, ip)
     |> load_requests()}
  end

  defp topic(value) when value in @topics, do: value
  defp topic(_value), do: ""

  defp contact_form(values, errors \\ []) do
    %{"topic" => "", "message" => "", "email" => "", "website" => ""}
    |> Map.merge(values)
    |> to_form(as: :contact, errors: errors)
  end

  defp load_requests(%{assigns: %{current_user: nil}} = socket), do: assign(socket, requests: nil)

  defp load_requests(socket) do
    case Api.get(socket, :accounts, "/api/me/support/requests") do
      {:ok, %{"requests" => requests}} when is_list(requests) ->
        assign(socket, requests: requests)

      _ ->
        assign(socket, requests: :unavailable)
    end
  end

  @impl true
  def handle_event("validate", %{"contact" => params}, socket),
    do:
      {:noreply,
       assign(socket, form: contact_form(Map.take(params, ~w(topic message email website))))}

  def handle_event("send", %{"contact" => params}, socket) do
    params = Map.take(params, ~w(topic message email website))

    cond do
      # the trap field is invisible to people: whoever fills it is refused, explicitly, and nothing is sent
      String.trim(to_string(params["website"])) != "" ->
        {:noreply, assign(socket, error: :trap, form: contact_form(params))}

      match?({:error, _}, RateLimit.check_ip(socket.private[:client_ip], :contact)) ->
        {:noreply, assign(socket, error: :ip_limit, form: contact_form(params))}

      true ->
        send_request(socket, params)
    end
  end

  def handle_event("new_request", _params, socket),
    do: {:noreply, assign(socket, sent: nil, error: nil, form: contact_form(%{}))}

  defp send_request(socket, params) do
    body =
      %{
        topic: params["topic"],
        message: params["message"],
        locale: Gettext.get_locale(MysticWeb.Gettext)
      }
      |> then(
        &if(socket.assigns.current_user, do: &1, else: Map.put(&1, :email, params["email"]))
      )

    case Api.post(socket, :accounts, "/api/support/requests", json: body) do
      {:ok, %{"request" => %{"reference" => _} = request} = result} ->
        address =
          if socket.assigns.current_user,
            do: socket.assigns.current_user["email"],
            else: String.trim(to_string(params["email"]))

        {:noreply,
         socket
         |> assign(
           sent: %{
             request: request,
             address: address,
             acknowledged: result["acknowledgement"] == "sent"
           },
           error: nil,
           form: contact_form(%{})
         )
         |> load_requests()}

      {:error, {:http, 422, _}} = error ->
        errors = Api.form_errors(error, [:topic, :message, :email])
        {:noreply, assign(socket, error: :invalid, form: contact_form(params, errors))}

      {:error, {:http, 429, _}} ->
        {:noreply, assign(socket, error: :quota, form: contact_form(params))}

      {:error, {:http, 401, _}} ->
        {:noreply, assign(socket, error: :session, form: contact_form(params))}

      _ ->
        {:noreply, assign(socket, error: :unavailable, form: contact_form(params))}
    end
  end

  # a reply of the team (its notification) or another tab: the list follows
  @impl true
  def handle_info({:notifications_changed, _user_id, _toast}, socket),
    do: {:noreply, load_requests(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

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
      <div class="contact-layout">
        <div class="min-w-0 space-y-6">
          <.page_header eyebrow={gettext("Help")} title={gettext("Contact us")}>
            {gettext(
              "A question, a problem, a request about your personal data? Write to the team. We can't promise a response time."
            )}
          </.page_header>

          <%= if @sent do %>
            <.access_state
              id="contact-sent"
              icon="hero-check-circle"
              tone="info"
              title={gettext("Request received")}
              live
            >
              <p>
                {gettext("Your reference: %{reference}.", reference: @sent.request["reference"])}
              </p>
              <p :if={@sent.acknowledged} id="contact-acknowledged">
                {gettext(
                  "An acknowledgement was sent to %{address}. For your security it doesn't repeat your message. The answer will come to the same address.",
                  address: @sent.address
                )}
              </p>
              <p :if={!@sent.acknowledged} id="contact-not-acknowledged">
                {gettext(
                  "Your request is recorded, but the acknowledgement e-mail could not be sent. The answer will still be sent to %{address}.",
                  address: @sent.address
                )}
              </p>
              <:actions>
                <.button type="button" phx-click="new_request" variant="secondary" id="contact-again">
                  {gettext("Send another request")}
                </.button>
                <.button navigate={~p"/help"} variant="ghost">{gettext("Help center")}</.button>
              </:actions>
            </.access_state>
          <% else %>
            <section class="card space-y-5" aria-labelledby="contact-form-title">
              <h2 id="contact-form-title" class="text-2xl">{gettext("Your request")}</h2>
              <div id="contact-error" aria-live="polite">
                <.contact_error error={@error} member={@current_user != nil} />
              </div>
              <.form
                for={@form}
                id="contact-form"
                phx-change="validate"
                phx-submit="send"
                class="space-y-5"
              >
                <.input
                  field={@form[:topic]}
                  type="select"
                  label={gettext("Topic")}
                  prompt={gettext("Choose a topic")}
                  options={for t <- topics(), do: {topic_label(t), t}}
                  required
                />
                <.input
                  :if={!@current_user}
                  field={@form[:email]}
                  type="email"
                  label={gettext("Your e-mail address")}
                  hint={gettext("We'll answer at this address. It is used for this request only.")}
                  autocomplete="email"
                  maxlength="160"
                  required
                />
                <p :if={@current_user} id="contact-member-address" class="text-sm text-muted">
                  {gettext("We'll answer at the address of your account: %{email}.",
                    email: @current_user["email"]
                  )}
                </p>
                <.input
                  field={@form[:message]}
                  type="textarea"
                  rows="7"
                  minlength="10"
                  maxlength="4000"
                  label={gettext("Message")}
                  hint={
                    gettext(
                      "10 to 4,000 characters. Never write a password, a code or a card number here."
                    )
                  }
                  required
                />
                <div class="hp-field">
                  <label for="contact-website">
                    {gettext("Leave this field empty (anti-spam check)")}
                  </label>
                  <input
                    type="text"
                    id="contact-website"
                    name="contact[website]"
                    value={@form[:website].value}
                    class="input"
                    tabindex="-1"
                    autocomplete="off"
                  />
                </div>
                <p class="text-xs text-muted">
                  {gettext("Your message is kept as described in the")}
                  <.link navigate={~p"/legal/privacy"} class="link">{gettext("privacy notice")}</.link>
                  {gettext("(deleted 180 days after the request is closed).")}
                </p>
                <.button type="submit" id="contact-submit" phx-disable-with={gettext("Sending…")}>
                  <.icon name="hero-paper-airplane" /> {gettext("Send my request")}
                </.button>
              </.form>
            </section>
          <% end %>
        </div>

        <aside class="space-y-4">
          <section class="card space-y-3" aria-labelledby="contact-before-title">
            <h2 id="contact-before-title" class="text-xl">{gettext("Before you write")}</h2>
            <ul class="space-y-1 text-sm">
              <li>
                <.link navigate={~p"/help"} class="help-link">{gettext("Help center")} →</.link>
              </li>
              <li>
                <.link navigate={~p"/forgot-password"} class="help-link">
                  {gettext("Forgot your password?")} →
                </.link>
              </li>
              <li>
                <.link navigate={~p"/settings/data"} class="help-link">
                  {gettext("Export or delete my data")} →
                </.link>
              </li>
              <li>
                <.link navigate={~p"/legal"} class="help-link">{gettext("Legal information")} →</.link>
              </li>
            </ul>
          </section>
        </aside>
      </div>

      <section
        :if={@current_user}
        id="my-requests"
        class="mt-10 space-y-4"
        aria-labelledby="my-requests-title"
      >
        <h2 id="my-requests-title" class="text-3xl">{gettext("Your requests")}</h2>
        <%= case @requests do %>
          <% :unavailable -> %>
            <.unavailable id="requests-unavailable">
              {gettext("Your requests can't be loaded right now.")}
            </.unavailable>
          <% [] -> %>
            <p id="requests-empty" class="text-muted">
              {gettext("You haven't sent any request yet.")}
            </p>
          <% requests -> %>
            <ul class="space-y-3">
              <li :for={r <- requests} id={"request-#{r["id"]}"} class="card space-y-3">
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <p class="font-medium text-ink">
                    {topic_label(r["topic"])} ·
                    <span class="font-mono text-sm">{r["reference"]}</span>
                  </p>
                  <.tag kind={if r["status"] == "answered", do: "success", else: "neutral"}>
                    {status_label(r["status"])}
                  </.tag>
                </div>
                <p class="text-xs text-muted">
                  {gettext("Sent %{date}", date: datetime(r["inserted_at"]))}
                </p>
                <details class="faq">
                  <summary>{gettext("Your message")}</summary>
                  <p class="whitespace-pre-wrap text-sm">{r["message"]}</p>
                </details>
                <div
                  :for={reply <- r["replies"] || []}
                  class="support-reply"
                  id={"reply-#{reply["id"]}"}
                >
                  <p class="text-xs text-muted">
                    {gettext("Reply from the MysticLore team · %{date}",
                      date: datetime(reply["inserted_at"])
                    )}
                  </p>
                  <p class="whitespace-pre-wrap text-sm">{reply["body"]}</p>
                </div>
              </li>
            </ul>
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  attr :error, :atom, default: nil
  attr :member, :boolean, default: false

  defp contact_error(assigns) do
    ~H"""
    <%= case @error do %>
      <% :trap -> %>
        <.notice kind="danger" role="alert" id="contact-trap">
          {gettext(
            "Your request was not sent: the field « Leave this field empty » is filled in. If you are a person, empty it and send again."
          )}
        </.notice>
      <% :ip_limit -> %>
        <.notice kind="danger" role="alert" id="contact-ip-limit">
          {gettext("Too many requests from your connection in the last hour. Please try again later.")}
        </.notice>
      <% :quota -> %>
        <.notice kind="danger" role="alert" id="contact-quota">
          {if @member,
            do:
              gettext(
                "You have already sent 5 requests in the last 24 hours. Please wait before sending another one."
              ),
            else:
              gettext(
                "This e-mail address has already received 3 acknowledgements in the last 24 hours. Please try again tomorrow, or log in to write from your account."
              )}
        </.notice>
      <% :invalid -> %>
        <.notice kind="warning" role="alert" id="contact-invalid">
          {gettext("Some information is invalid. Please check the highlighted fields.")}
        </.notice>
      <% :session -> %>
        <.notice kind="warning" role="alert" id="contact-session">
          {gettext("Your session has ended. Please log in again, then send your request.")}
        </.notice>
      <% :unavailable -> %>
        <.notice kind="warning" role="alert" id="contact-unavailable">
          {gettext(
            "Your request could not be sent: the service is temporarily unavailable. Nothing was recorded; please try again in a moment."
          )}
        </.notice>
      <% nil -> %>
    <% end %>
    """
  end
end
