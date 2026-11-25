defmodule MlBillingWeb.ErrorJSON do
  @moduledoc "Errors raised outside controllers (404 route, 400 bad JSON, 500…): `{\"error\": code}`."

  def render(template, _assigns) do
    status = template |> String.split(".") |> hd() |> String.to_integer()
    %{error: status |> Plug.Conn.Status.reason_atom() |> Atom.to_string()}
  end
end
