defmodule MlSocialWeb.SettingsController do
  @moduledoc "Réglages de confidentialité du membre (`MlSocial.Settings`) : `GET` et `PATCH /api/me/settings`."
  use MlSocialWeb, :controller
  alias MlSocial.{Setting, Settings}

  action_fallback MlSocialWeb.FallbackController

  def show(conn, _params),
    do: json(conn, %{settings: Setting.to_map(Settings.get(conn.assigns.user_id))})

  def update(conn, params) do
    attrs =
      Map.take(params, ~w(show_online read_receipts friend_requests group_adds lobby_invites))

    with {:ok, setting} <- Settings.update(conn.assigns.user_id, attrs),
         do: json(conn, %{settings: Setting.to_map(setting)})
  end
end
