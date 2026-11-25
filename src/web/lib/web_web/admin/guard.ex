defmodule MysticWeb.Admin.Guard do
  @moduledoc """
  Checks the staff role at mount and on every event, so a moderator's forged admin event is refused before any call.
  """
  use Gettext, backend: MysticWeb.Gettext
  import Phoenix.LiveView

  def staff?(%{"role" => role}), do: role in ~w(moderator admin)
  def staff?(_), do: false

  def admin?(%{"role" => "admin"}), do: true
  def admin?(_), do: false

  defp allowed?(:staff, user), do: staff?(user)
  defp allowed?(:admin, user), do: admin?(user)

  def on_mount(level, _params, _session, socket) when level in [:staff, :admin] do
    if allowed?(level, socket.assigns[:current_user]) do
      {:cont,
       socket
       |> Phoenix.Component.assign(:admin_level, level)
       |> attach_hook(:admin_guard, :handle_event, &guard_event/3)
       |> attach_hook(:admin_role, :handle_info, &guard_info/2)}
    else
      raise MysticWeb.ForbiddenError
    end
  end

  defp guard_event(event, _params, socket) do
    user = socket.assigns.current_user

    cond do
      not allowed?(socket.assigns.admin_level, user) ->
        {:halt, leave(socket)}

      event in admin_events(socket.view) and not admin?(user) ->
        {:halt, put_flash(socket, :error, gettext("Only admins can do that."))}

      true ->
        {:cont, socket}
    end
  end

  defp guard_info({:role_changed, _user_id}, socket) do
    if allowed?(socket.assigns.admin_level, socket.assigns.current_user),
      do: {:cont, socket},
      else: {:halt, leave(socket)}
  end

  defp guard_info(_message, socket), do: {:cont, socket}

  defp leave(socket) do
    socket
    |> put_flash(:error, gettext("You no longer have access to this page."))
    |> push_navigate(to: "/dashboard")
  end

  defp admin_events(view),
    do: if(function_exported?(view, :admin_events, 0), do: view.admin_events(), else: [])
end
