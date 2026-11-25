defmodule MlSocialWeb.AttachmentTest do
  @moduledoc """
  Pièces jointes : signatures, tailles, métadonnées, texte alternatif, accès et PDF.
  Synchrone, car un test compare le contenu du répertoire de stockage partagé.
  """
  use MlSocialWeb.ConnCase, async: false
  import MlShared.ImageFixtures
  alias MlSocial.{Attachment, Repo}

  setup do
    [a, b, c] = for _ <- 1..3, do: uuid()
    %{a: a, b: b, c: c, conversation: conversation_between(a, b)}
  end

  defp post_file(ctx, attachment, extra \\ %{}),
    do:
      api(
        :post,
        "/api/conversations/#{ctx.conversation.id}/messages",
        ctx.a,
        Map.put(extra, :attachment, attachment)
      )

  defp download(id, user), do: api(:get, "/api/attachments/#{id}", user)

  defp stored(id) do
    %Attachment{storage_key: key} = Repo.get!(Attachment, id)
    File.read!(Path.join([Application.fetch_env!(:social, :storage_dir), "attachments", key]))
  end

  describe "formats reconnus aux octets magiques" do
    test "PNG, JPEG, WebP et PDF acceptés, quel que soit le nom annoncé", ctx do
      for {bytes, name, kind, type, filename} <- [
            {png(), "photo.pdf", "image", "image/png", "photo.png"},
            {jpeg(), "x", "image", "image/jpeg", "x.jpg"},
            {webp_vp8l(), "y.png", "image", "image/webp", "y.webp"},
            {pdf(), "notes.png", "pdf", "application/pdf", "notes.pdf"}
          ] do
        assert %{"message" => %{"body" => nil, "attachment" => attachment}} =
                 post_file(ctx, attachment(bytes, name)) |> json_response(201)

        # extension réelle, jamais celle annoncée
        assert %{
                 "kind" => ^kind,
                 "content_type" => ^type,
                 "filename" => ^filename,
                 "scan" => "unscanned",
                 "available" => true
               } = attachment
      end
    end

    test "texte renommé, GIF, SVG, base64 invalide : refusés (422), rien n'est stocké", ctx do
      for bytes <- ["just text renamed photo.png", "GIF89a" <> :binary.copy(<<0>>, 64), "<svg/>"] do
        assert %{
                 "errors" => %{
                   "attachment" => ["must be a PNG, JPEG or WebP image, or a PDF document"]
                 }
               } =
                 post_file(ctx, attachment(bytes, "photo.png")) |> json_response(422)
      end

      assert %{"errors" => %{"attachment" => ["is invalid"]}} =
               post_file(ctx, %{"data_base64" => "%%% not base64"}) |> json_response(422)

      assert %{"errors" => %{"attachment" => ["is invalid"]}} =
               post_file(ctx, "nope") |> json_response(422)

      assert %{"errors" => %{"attachment" => ["is not a valid image file"]}} =
               post_file(ctx, attachment(binary_part(png(), 0, 40))) |> json_response(422)

      assert Repo.aggregate(Attachment, :count) == 0
    end

    test "tailles : images 5 Mo, PDF 10 Mo au plus", ctx do
      big_png = png(64, 64) <> :binary.copy(<<0>>, 5 * 1024 * 1024)

      assert %{"errors" => %{"attachment" => ["images must be at most 5 MB"]}} =
               post_file(ctx, attachment(big_png)) |> json_response(422)

      assert %{"errors" => %{"attachment" => ["PDF documents must be at most 10 MB"]}} =
               post_file(ctx, attachment(pdf(10 * 1024 * 1024 + 1))) |> json_response(422)

      assert %{"message" => %{"attachment" => %{"byte_size" => size}}} =
               post_file(ctx, attachment(pdf(10 * 1024 * 1024))) |> json_response(201)

      assert size == 10 * 1024 * 1024
    end
  end

  describe "contenu" do
    test "métadonnées retirées avant le stockage ; texte alternatif ; nom nettoyé", ctx do
      original = jpeg(320, 200, [jfif(), exif_gps(), comment_jpeg()])

      assert %{"message" => %{"body" => "Our map", "attachment" => a}} =
               post_file(
                 ctx,
                 attachment(original, "../../etc/\u0007map.jpeg", "  A hand-drawn map  "),
                 %{
                   body: "Our map"
                 }
               )
               |> json_response(201)

      assert %{
               "alt" => "A hand-drawn map",
               "filename" => "map.jpg",
               "width" => 320,
               "height" => 200
             } = a

      clean = stored(a["id"])
      refute clean =~ "SECRET"
      refute clean =~ "Exif"
      assert download(a["id"], ctx.b) |> response(200) == clean

      assert %{"errors" => %{"alt" => ["should be at most 300 character(s)"]}} =
               post_file(ctx, attachment(png(), "p.png", String.duplicate("a", 301)))
               |> json_response(422)

      # PDF : pas de texte alternatif (ignoré)
      assert %{"message" => %{"attachment" => %{"alt" => nil, "filename" => "document.pdf"}}} =
               post_file(ctx, attachment(pdf(), "", "ignored")) |> json_response(201)
    end
  end

  describe "accès" do
    test "membres seulement, vérifié à chaque téléchargement ; type d'après le fichier, nosniff, no-store",
         ctx do
      %{"message" => %{"attachment" => %{"id" => id}}} =
        post_file(ctx, attachment(pdf(), "guide.pdf")) |> json_response(201)

      conn = download(id, ctx.b)
      assert response(conn, 200) |> String.starts_with?("%PDF-")
      assert get_resp_header(conn, "content-type") == ["application/pdf"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "cache-control") == ["private, no-store"]

      # non-membre, inconnu, mal formé : même 404
      for {who, attachment_id} <- [{ctx.c, id}, {ctx.b, uuid()}, {ctx.b, "nope"}] do
        assert %{"error" => "not_found"} = download(attachment_id, who) |> json_response(404)
      end
    end

    test "un membre retiré d'un groupe n'ouvre plus les pièces jointes", ctx do
      group = group!(ctx.a, [ctx.b, ctx.c])

      %{"message" => %{"attachment" => %{"id" => id}}} =
        api(:post, "/api/conversations/#{group.id}/messages", ctx.a, %{
          attachment: attachment(png(16, 16), "group.png")
        })
        |> json_response(201)

      assert download(id, ctx.c) |> response(200)
      api(:delete, "/api/conversations/#{group.id}/members/#{ctx.c}", ctx.a) |> json_response(200)
      assert download(id, ctx.c) |> json_response(404)
      assert download(id, ctx.b) |> response(200)
    end

    test "un envoi refusé ne laisse aucun fichier ; l'envoi à un non-ami est refusé avant l'analyse",
         ctx do
      dir = Path.join(Application.fetch_env!(:social, :storage_dir), "attachments")
      File.mkdir_p!(dir)
      before = File.ls!(dir)
      api(:delete, "/api/friends/#{ctx.b}", ctx.a) |> response(204)

      assert %{"error" => "not_friends"} =
               post_file(ctx, attachment(png(), "late.png")) |> json_response(403)

      assert File.ls!(dir) -- before == []
    end
  end
end
