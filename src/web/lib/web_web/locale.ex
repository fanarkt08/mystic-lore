defmodule MysticWeb.Locale do
  @moduledoc """
  Picks the visitor's language from the `ml_locale` cookie or `Accept-Language`.
  """
  import Plug.Conn

  @supported ~w(en fr)
  @cookie "ml_locale"

  def supported, do: @supported
  def cookie, do: @cookie

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)

    locale =
      if conn.cookies[@cookie] in @supported,
        do: conn.cookies[@cookie],
        else: conn |> get_req_header("accept-language") |> from_header()

    Gettext.put_locale(MysticWeb.Gettext, locale)
    if get_session(conn, "locale") == locale, do: conn, else: put_session(conn, "locale", locale)
  end

  def on_mount(:default, _params, session, socket) do
    locale = if session["locale"] in @supported, do: session["locale"], else: "en"
    Gettext.put_locale(MysticWeb.Gettext, locale)
    {:cont, socket}
  end

  @doc "Best supported language of `Accept-Language` header values (q-values honoured)."
  def from_header(values) do
    values
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&parse/1)
    |> Enum.filter(fn {lang, q} -> lang in @supported and q > 0 end)
    |> Enum.sort_by(fn {_lang, q} -> -q end)
    |> case do
      [{lang, _q} | _] -> lang
      [] -> "en"
    end
  end

  defp parse(part) do
    [tag | params] = String.split(part, ";")
    lang = tag |> String.trim() |> String.downcase() |> String.split("-") |> hd()

    q =
      Enum.find_value(params, 1.0, fn param ->
        with ["q", value] <- param |> String.trim() |> String.split("="),
             {q, _} <- Float.parse(value),
             do: q,
             else: (_ -> nil)
      end)

    {lang, q}
  end

  @doc """
  A path of this site to go back to (`/adventures?page=2`), or `"/"`: never an absolute or protocol-relative
  URL, a backslash or a control character (no open redirect).
  """
  def local_path(path) when is_binary(path) and byte_size(path) <= 2048 do
    with false <- String.contains?(path, ["\\", "\r", "\n", "\t", <<0>>]),
         {:ok, %URI{scheme: nil, host: nil, userinfo: nil, path: "/" <> _ = p} = uri} <-
           URI.new(path),
         false <- String.starts_with?(p, "//") do
      if uri.query, do: p <> "?" <> uri.query, else: p
    else
      _ -> "/"
    end
  end

  def local_path(_path), do: "/"
end
