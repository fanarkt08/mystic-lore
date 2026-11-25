defmodule MlSocial.Scanner.Clamd do
  @moduledoc "Adaptateur clamd en TCP (protocole INSTREAM) ; toute réponse autre que `OK` ou `FOUND` est une erreur."
  @behaviour MlSocial.Scanner

  @chunk 65_536

  @impl true
  def scan(bytes, opts) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    host = opts |> Keyword.fetch!(:host) |> String.to_charlist()
    tcp = [:binary, active: false, packet: :raw, send_timeout: timeout, send_timeout_close: true]

    with {:ok, socket} <- :gen_tcp.connect(host, Keyword.get(opts, :port, 3310), tcp, timeout) do
      try do
        with :ok <- :gen_tcp.send(socket, "zINSTREAM\0"),
             :ok <- send_chunks(socket, bytes),
             {:ok, reply} <- reply(socket, deadline, "") do
          verdict(reply)
        end
      after
        :gen_tcp.close(socket)
      end
    end
  end

  defp send_chunks(socket, <<chunk::binary-size(@chunk), rest::binary>>) do
    with :ok <- :gen_tcp.send(socket, [<<@chunk::32>>, chunk]), do: send_chunks(socket, rest)
  end

  defp send_chunks(socket, last),
    do: :gen_tcp.send(socket, [<<byte_size(last)::32>>, last, <<0::32>>])

  # Jusqu'au `\0` final (ou la fermeture par clamd), dans le délai restant.
  defp reply(socket, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      String.contains?(acc, <<0>>) ->
        {:ok, acc}

      remaining <= 0 ->
        {:error, :timeout}

      true ->
        case :gen_tcp.recv(socket, 0, remaining) do
          {:ok, data} -> reply(socket, deadline, acc <> data)
          {:error, :closed} when acc != "" -> {:ok, acc}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp verdict(reply) do
    case reply |> String.split(<<0>>) |> hd() |> String.trim() do
      "stream: OK" ->
        :clean

      "stream: " <> found ->
        if String.ends_with?(found, " FOUND"),
          do: {:infected, String.trim_trailing(found, " FOUND")},
          else: {:error, {:clamd, found}}

      other ->
        {:error, {:clamd, other}}
    end
  end
end
