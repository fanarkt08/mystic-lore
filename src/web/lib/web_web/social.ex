defmodule MysticWeb.Social do
  @moduledoc """
  Friendship, block and report actions (social service) shared by the friends and member pages,
  with their UI pieces. Every action is authorized by social itself.
  """
  use Phoenix.Component
  use Gettext, backend: MysticWeb.Gettext
  import MysticWeb.CoreComponents
  alias MysticWeb.Api

  @actions ~w(add accept decline cancel remove block unblock)
  def actions, do: @actions

  @doc "Runs a member action and returns `{:ok, message}` or `{:error, message}`."
  def act(socket, "add", user_id) do
    case Api.post(socket, :social, "/api/friend-requests", json: %{user_id: user_id}) do
      {:ok, %{"status" => "accepted"}} -> {:ok, gettext("You are now friends!")}
      {:ok, _} -> {:ok, gettext("Friend request sent.")}
      error -> {:error, Api.error_message(error)}
    end
  end

  def act(socket, "accept", request_id),
    do: request(socket, "accept", request_id, gettext("Friend request accepted."))

  def act(socket, "decline", request_id),
    do: request(socket, "decline", request_id, gettext("Friend request declined."))

  def act(socket, "cancel", request_id),
    do: request(socket, "decline", request_id, gettext("Friend request canceled."))

  def act(socket, "remove", user_id) do
    Api.delete(socket, :social, "/api/friends/:id", path_params: [id: user_id])
    |> result(gettext("Friend removed."))
  end

  def act(socket, "block", user_id) do
    Api.post(socket, :social, "/api/blocks", json: %{user_id: user_id})
    |> result(gettext("Member blocked. You won't receive their requests or messages anymore."))
  end

  def act(socket, "unblock", user_id) do
    Api.delete(socket, :social, "/api/blocks/:id", path_params: [id: user_id])
    |> result(gettext("Member unblocked."))
  end

  defp request(socket, verb, request_id, message) do
    case Api.post(socket, :social, "/api/friend-requests/:id/#{verb}",
           path_params: [id: request_id]
         ) do
      {:error, {:http, 404, _}} -> {:error, gettext("This request is no longer pending.")}
      other -> result(other, message)
    end
  end

  defp result({:ok, _}, message), do: {:ok, message}
  defp result(error, _message), do: {:error, Api.error_message(error)}

  @doc "Opens (or reuses) the conversation with a friend: `{:ok, conversation_id}` or `{:error, message}`."
  def open_conversation(socket, user_id) do
    case Api.post(socket, :social, "/api/conversations", json: %{user_id: user_id}) do
      {:ok, %{"conversation" => %{"id" => id}}} -> {:ok, id}
      error -> {:error, Api.error_message(error)}
    end
  end

  @doc "Reports a member (`target_type: user`)."
  def report(socket, user_id, %{"reason" => reason} = params) do
    body = %{target_type: "user", target_id: user_id, reason: reason, details: params["details"]}

    case Api.post(socket, :social, "/api/reports", json: body) do
      {:ok, _} -> {:ok, gettext("Report sent. Thank you — the moderators will review it.")}
      error -> {:error, Api.error_message(error)}
    end
  end

  @doc "Reports a message of a conversation (`target_type: message`; social keeps a snapshot for the moderators)."
  def report_message(socket, message_id, %{"reason" => reason} = params) do
    body = %{
      target_type: "message",
      target_id: message_id,
      reason: reason,
      details: params["details"]
    }

    case Api.post(socket, :social, "/api/reports", json: body) do
      {:ok, _} -> {:ok, gettext("Report sent. Thank you — the moderators will review it.")}
      error -> {:error, Api.error_message(error)}
    end
  end

  @doc "Friends, pending requests and blocks of the current user, or `:unavailable`."
  def relations(socket) do
    with {:ok, %{"friends" => friends}} <- Api.get(socket, :social, "/api/me/friends"),
         {:ok, %{} = requests} <- Api.get(socket, :social, "/api/me/friend-requests"),
         {:ok, %{} = blocks} <- Api.get(socket, :social, "/api/me/blocks") do
      %{
        friends: friends,
        incoming: requests["incoming"] || [],
        outgoing: requests["outgoing"] || [],
        blocks: blocks["blocks"] || []
      }
    else
      _ -> :unavailable
    end
  end

  @doc "Relation of the current user with `user_id`, from `relations/1`."
  def relation(:unavailable, _user_id), do: :unknown

  def relation(rel, user_id) do
    cond do
      Enum.any?(rel.blocks, &(&1["id"] == user_id)) -> :blocked
      Enum.any?(rel.friends, &(&1["id"] == user_id)) -> :friend
      req = Enum.find(rel.incoming, &(&1["from"]["id"] == user_id)) -> {:incoming, req["id"]}
      req = Enum.find(rel.outgoing, &(&1["to"]["id"] == user_id)) -> {:outgoing, req["id"]}
      true -> :none
    end
  end

  @doc "Friend / message / block / report buttons for a member, according to the relation."
  attr :user, :map, required: true
  attr :relation, :any, required: true
  attr :compact, :boolean, default: false

  def member_actions(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <%= case @relation do %>
        <% :friend -> %>
          <.button phx-click="message" phx-value-id={@user["id"]} variant="secondary">
            <.icon name="hero-chat-bubble-left-right" /> {gettext("Message")}
          </.button>
          <.button
            :if={!@compact}
            phx-click="remove"
            phx-value-id={@user["id"]}
            variant="ghost"
            data-confirm={gettext("Remove this friend?")}
          >
            {gettext("Remove friend")}
          </.button>
        <% {:incoming, request_id} -> %>
          <.button phx-click="accept" phx-value-id={request_id}>
            <.icon name="hero-check" /> {gettext("Accept request")}
          </.button>
        <% {:outgoing, request_id} -> %>
          <.button phx-click="cancel" phx-value-id={request_id} variant="secondary">
            {gettext("Cancel request")}
          </.button>
        <% :blocked -> %>
          <.button phx-click="unblock" phx-value-id={@user["id"]} variant="secondary">
            {gettext("Unblock")}
          </.button>
        <% :none -> %>
          <.button phx-click="add" phx-value-id={@user["id"]}>
            <.icon name="hero-user-plus" /> {gettext("Add friend")}
          </.button>
        <% _ -> %>
      <% end %>
      <.button
        :if={!@compact and @relation not in [:blocked, :unknown]}
        phx-click="block"
        phx-value-id={@user["id"]}
        variant="ghost"
        data-confirm={gettext("Block this member? This also removes your friendship and requests.")}
      >
        <.icon name="hero-no-symbol" /> {gettext("Block")}
      </.button>
      <.button
        :if={!@compact}
        phx-click="report"
        phx-value-id={@user["id"]}
        variant="ghost"
      >
        <.icon name="hero-flag" /> {gettext("Report")}
      </.button>
    </div>
    """
  end

  @doc "Report form for a member or one of their messages (shown inline, focused when it appears)."
  attr :user, :map, required: true
  attr :title, :string, default: nil

  def report_panel(assigns) do
    ~H"""
    <section
      id="report-panel"
      class="card space-y-4 border-danger/40"
      aria-labelledby="report-title"
      phx-hook="ReturnFocus"
      data-return-focus
      phx-mounted={Phoenix.LiveView.JS.focus_first(to: "#report-panel")}
    >
      <h2 id="report-title" class="text-2xl">
        {@title || gettext("Report %{name}", name: @user["display_name"])}
      </h2>
      <p class="text-sm text-muted">
        {gettext("Reports are confidential and reviewed by the moderation team.")}
      </p>
      <.form for={%{}} as={:report} id="report-form" phx-submit="submit_report" class="space-y-4">
        <.input
          id="report-reason"
          name="report[reason]"
          value="harassment"
          type="select"
          label={gettext("Reason")}
          options={[
            {gettext("Harassment"), "harassment"},
            {gettext("Spam"), "spam"},
            {gettext("Inappropriate content"), "inappropriate"},
            {gettext("Other"), "other"}
          ]}
        />
        <.input
          id="report-details"
          name="report[details]"
          value=""
          type="textarea"
          rows="3"
          maxlength="1000"
          label={gettext("Details (optional)")}
        />
        <div class="flex flex-wrap gap-2">
          <.button type="submit" variant="danger">{gettext("Send report")}</.button>
          <.button type="button" phx-click="cancel_report" variant="ghost">
            {gettext("Cancel")}
          </.button>
        </div>
      </.form>
    </section>
    """
  end
end
