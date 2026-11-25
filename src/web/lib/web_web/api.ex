defmodule MysticWeb.Api do
  @moduledoc """
  Calls the internal services on behalf of the current user and turns their errors into user-facing messages.
  """
  use Gettext, backend: MysticWeb.Gettext
  alias MlShared.Client

  def get(who, service, path, opts \\ []), do: request(who, :get, service, path, opts)
  def post(who, service, path, opts \\ []), do: request(who, :post, service, path, opts)
  def put(who, service, path, opts \\ []), do: request(who, :put, service, path, opts)
  def patch(who, service, path, opts \\ []), do: request(who, :patch, service, path, opts)
  def delete(who, service, path, opts \\ []), do: request(who, :delete, service, path, opts)

  defp request(who, method, service, path, opts),
    do: Client.request(service, method, path, [as: user_id(who)] ++ opts)

  def user_id(%Phoenix.LiveView.Socket{assigns: assigns}), do: user_id(assigns[:current_user])
  def user_id(%{"id" => id}), do: id
  def user_id(_), do: nil

  @doc "accounts `GET /api/sessions/current` for a browser session token."
  def current_session(token),
    do: Client.get(:accounts, "/api/sessions/current", headers: [{"x-session-token", token}])

  @doc "accounts `DELETE /api/sessions/current` (revokes the browser session token)."
  def revoke_session(token),
    do: Client.delete(:accounts, "/api/sessions/current", headers: [{"x-session-token", token}])

  @doc "The `error` code of an error body (`{\"error\": code}`), if any."
  def error_code({:error, {:http, _status, %{"error" => code}}}) when is_binary(code), do: code
  def error_code(_), do: nil

  @doc "Form errors (`[field: {message, []}]`) of a 422 response, restricted to the given form fields."
  def form_errors({:error, {:http, 422, %{"errors" => errors}}}, fields) when is_map(errors) do
    for {name, messages} <- errors,
        field = Enum.find(fields, &(Atom.to_string(&1) == name)),
        message <- List.wrap(messages),
        is_binary(message),
        do: {field, {message, []}}
  end

  def form_errors(_result, _fields), do: []

  @doc "A clear, translated message for an error returned by `MlShared.Client`."
  def error_message({:error, reason}), do: error_message(reason)

  def error_message(:unavailable),
    do: gettext("This service is temporarily unavailable. Please try again in a moment.")

  def error_message({:http, 403, %{"error" => "restricted", "restricted_until" => until}}),
    do:
      gettext(
        "Your account is restricted until %{date}: you can't send messages, post in the forum or write in lobby chats until then.",
        date: MysticWeb.Format.message_time(until)
      )

  def error_message({:http, 429, %{"error" => "rate_limited", "retry_after" => seconds}})
      when is_integer(seconds),
      do:
        ngettext(
          "You're sending messages too quickly. You can send again in %{count} second.",
          "You're sending messages too quickly. You can send again in %{count} seconds.",
          seconds
        )

  def error_message({:http, status, body}),
    do: status_message(status, error_code({:error, {:http, status, body}}))

  defp status_message(401, _), do: gettext("Your session has expired. Please log in again.")
  defp status_message(402, _), do: gettext("This requires a Premium membership.")

  defp status_message(403, "blocked"),
    do: gettext("This isn't possible: one of you has blocked the other.")

  defp status_message(403, "not_friends"),
    do: gettext("You can only message members who are your friends.")

  defp status_message(403, "friend_requests_closed"),
    do: gettext("This member doesn't accept friend requests from you.")

  defp status_message(403, "group_adds_closed"),
    do: gettext("This member doesn't accept being added to groups.")

  defp status_message(403, "lobby_invites_closed"),
    do: gettext("This member doesn't accept activity invitations.")

  defp status_message(403, "not_owner"), do: gettext("Only the owner of the group can do that.")

  defp status_message(403, "same_staff"),
    do: gettext("You issued this sanction: another staff member has to decide the appeal.")

  defp status_message(403, "self"), do: gettext("You can't do that to your own account.")
  defp status_message(403, _), do: gettext("You don't have permission to do that.")
  defp status_message(404, _), do: gettext("We couldn't find what you were looking for.")
  defp status_message(409, "already_friends"), do: gettext("You are already friends.")

  defp status_message(409, "already_requested"),
    do: gettext("A friend request is already pending between you.")

  defp status_message(409, "already_subscribed"), do: gettext("You already have this plan.")
  defp status_message(409, "group_full"), do: gettext("This group already has 20 members.")
  defp status_message(409, "already_member"), do: gettext("This member is already in the group.")
  defp status_message(409, "checkout_completed"), do: gettext("This checkout is already paid.")

  defp status_message(409, "checkout_expired"),
    do: gettext("This checkout has expired. Start a new one from the membership page.")

  defp status_message(409, "last_admin"),
    do: gettext("The academy must keep at least one active admin.")

  defp status_message(409, "staff_target"),
    do: gettext("Staff members can't be sanctioned. Change their role first.")

  defp status_message(409, "appeal_open"), do: gettext("An appeal is already under review.")

  defp status_message(409, "closed"),
    do: gettext("This request is closed: reopen it before answering.")

  defp status_message(409, "not_appealable"),
    do: gettext("This sanction is no longer active: there is nothing to appeal.")

  defp status_message(409, code) when code in ["already_resolved", "already_decided"],
    do: gettext("Someone already handled this. Please refresh.")

  defp status_message(409, _),
    do: gettext("This conflicts with the current state. Please refresh and try again.")

  defp status_message(422, "self"), do: gettext("You can't add yourself as a friend.")

  defp status_message(422, _),
    do: gettext("Some information is invalid. Please check it and try again.")

  defp status_message(429, _), do: gettext("Too many attempts. Please wait and try again.")

  defp status_message(502, "provider_error"),
    do: gettext("The payment provider didn't respond. Please try again in a moment.")

  defp status_message(503, "payments_disabled"),
    do: gettext("Payments are not configured on this server.")

  defp status_message(503, "entitlements_unavailable"),
    do: gettext("Premium access can't be verified right now. Please try again in a moment.")

  defp status_message(503, "scanner_unavailable"),
    do:
      gettext(
        "The antivirus can't check files right now, so nothing was sent. Please try again in a moment."
      )

  defp status_message(503, "audit_unavailable"),
    do:
      gettext("The audit log can't be written right now, so nothing was done. Please try again.")

  defp status_message(status, _) when status >= 500, do: error_message(:unavailable)
  defp status_message(_, _), do: gettext("Something went wrong. Please try again.")
end
