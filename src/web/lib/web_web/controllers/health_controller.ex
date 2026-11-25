defmodule MysticWeb.HealthController do
  @moduledoc "Liveness probe (web has no database)."
  use MysticWeb, :controller

  def show(conn, _params), do: json(conn, %{status: "ok"})
end
