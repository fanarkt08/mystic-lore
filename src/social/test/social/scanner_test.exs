defmodule MlSocial.ScannerTest do
  @moduledoc """
  Antivirus : protocole INSTREAM de clamd contre un faux serveur TCP local (aucun ClamAV installé), puis l'envoi
  d'une pièce jointe selon la configuration. Synchrone : la configuration du scanner est globale.
  """
  use MlSocialWeb.ConnCase, async: false
  import MlShared.ImageFixtures, only: [png: 0, pdf: 1]
  alias MlSocial.{Attachment, Repo, Scanner}
  alias MlSocial.Scanner.Clamd

  @eicar "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"

  # Faux clamd : lit `zINSTREAM\0` puis les blocs jusqu'au bloc vide, envoie au test ce qu'il a reçu, répond
  # `OK` ou `FOUND` (signature EICAR), une réponse donnée (`{:reply, octets}`), ou ne répond jamais (`:silent`).
  defp fake_clamd(mode \\ :answer) do
    test = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, "zINSTREAM\0"} = :gen_tcp.recv(socket, 10)
        {data, chunks} = read_chunks(socket, [], 0)
        send(test, {:clamd_received, data, chunks})

        case mode do
          :silent -> :ok
          :answer -> :gen_tcp.send(socket, verdict(data))
          {:reply, reply} -> :gen_tcp.send(socket, reply)
        end

        Process.sleep(:infinity)
      end)

    on_exit(fn ->
      Process.unlink(server)
      Process.exit(server, :kill)
      :gen_tcp.close(listen)
    end)

    port
  end

  defp read_chunks(socket, acc, count) do
    {:ok, <<size::32>>} = :gen_tcp.recv(socket, 4)

    if size == 0 do
      {IO.iodata_to_binary(Enum.reverse(acc)), count}
    else
      {:ok, chunk} = :gen_tcp.recv(socket, size)
      read_chunks(socket, [chunk | acc], count + 1)
    end
  end

  defp verdict(data) do
    if String.contains?(data, "EICAR-STANDARD-ANTIVIRUS-TEST-FILE"),
      do: "stream: Eicar-Test-Signature FOUND\0",
      else: "stream: OK\0"
  end

  defp opts(port, timeout \\ 2_000), do: [host: "127.0.0.1", port: port, timeout: timeout]

  defp closed_port do
    {:ok, listen} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    port
  end

  describe "adaptateur clamd (INSTREAM en TCP)" do
    test "fichier sain : OK ; le flux reçu est exactement le fichier, découpé en blocs de 64 Kio" do
      bytes = :crypto.strong_rand_bytes(150_000)
      assert :clean = Clamd.scan(bytes, opts(fake_clamd()))
      assert_received {:clamd_received, ^bytes, 3}
    end

    test "signature reconnue : FOUND → infecté, avec le nom de la signature" do
      assert {:infected, "Eicar-Test-Signature"} = Clamd.scan(@eicar, opts(fake_clamd()))
    end

    test "délai maximal : un clamd muet est abandonné à temps" do
      port = fake_clamd(:silent)
      {us, result} = :timer.tc(fn -> Clamd.scan("hello", opts(port, 300)) end)
      assert {:error, :timeout} = result
      assert us < 1_000_000
    end

    test "clamd injoignable ou réponse inattendue : erreur" do
      assert {:error, :econnrefused} = Clamd.scan("hello", opts(closed_port()))

      port = fake_clamd({:reply, "INSTREAM size limit exceeded. ERROR\0"})

      assert {:error, {:clamd, "INSTREAM size limit exceeded. ERROR"}} =
               Clamd.scan("hello", opts(port))
    end
  end

  describe "envoi d'une pièce jointe selon l'antivirus" do
    setup do
      [a, b] = [uuid(), uuid()]
      on_exit(fn -> Application.delete_env(:social, :scanner) end)
      %{a: a, conversation: conversation_between(a, b)}
    end

    defp post_file(ctx, bytes, name) do
      api(:post, "/api/conversations/#{ctx.conversation.id}/messages", ctx.a, %{
        attachment: attachment(bytes, name)
      })
    end

    test "non configuré : accepté mais « unscanned », jamais présenté comme analysé", ctx do
      Application.delete_env(:social, :scanner)
      assert {:ok, "unscanned"} = Scanner.check("anything")

      assert %{"message" => %{"attachment" => %{"scan" => "unscanned"}}} =
               post_file(ctx, png(), "a.png") |> json_response(201)
    end

    @tag :capture_log
    test "configuré : sain → « clean » ; infecté → refusé (422), rien n'est stocké", ctx do
      Application.put_env(:social, :scanner, {Clamd, opts(fake_clamd())})

      assert %{"message" => %{"attachment" => %{"scan" => "clean"}}} =
               post_file(ctx, png(), "a.png") |> json_response(201)

      # le PDF porte la signature de test EICAR
      Application.put_env(:social, :scanner, {Clamd, opts(fake_clamd())})
      infected = pdf(0) <> @eicar
      before = Repo.aggregate(Attachment, :count)

      assert %{"errors" => %{"attachment" => ["was rejected by the antivirus"]}} =
               post_file(ctx, infected, "virus.pdf") |> json_response(422)

      assert Repo.aggregate(Attachment, :count) == before
    end

    @tag :capture_log
    test "configuré mais injoignable ou trop lent : refusé (503), la sécurité l'emporte", ctx do
      Application.put_env(:social, :scanner, {Clamd, opts(closed_port())})

      assert %{"error" => "scanner_unavailable"} =
               post_file(ctx, png(), "a.png") |> json_response(503)

      Application.put_env(:social, :scanner, {Clamd, opts(fake_clamd(:silent), 200)})

      assert %{"error" => "scanner_unavailable"} =
               post_file(ctx, png(), "a.png") |> json_response(503)

      assert Repo.aggregate(Attachment, :count) == 0
    end
  end
end
