defmodule MlShared.ImageTest do
  use ExUnit.Case, async: true
  import MlShared.ImageFixtures
  alias MlShared.Image

  # bornes des avatars d'accounts ; les pièces jointes de social passent les leurs
  @avatar [max_bytes: 2_097_152, sides: 64..2048]

  defp sanitize(bytes, opts \\ @avatar), do: Image.sanitize(bytes, opts)

  describe "signatures (magic bytes only)" do
    test "PNG, JPEG and WebP are recognised by their bytes" do
      assert {:ok, %{type: "image/png", ext: "png", width: 64, height: 64}} = sanitize(png())
      assert {:ok, %{type: "image/jpeg", ext: "jpg"}} = sanitize(jpeg())
      assert {:ok, %{type: "image/webp", ext: "webp"}} = sanitize(webp_vp8l())
    end

    test "anything else is refused, whatever its name would say" do
      assert {:error, :unsupported} = sanitize("just some text, renamed avatar.png")
      assert {:error, :unsupported} = sanitize("GIF89a" <> :binary.copy(<<0>>, 100))
      assert {:error, :unsupported} = sanitize("<svg xmlns='http://www.w3.org/2000/svg'/>")
      assert {:error, :unsupported} = sanitize(pdf())
      assert {:error, :unsupported} = sanitize("")
    end
  end

  describe "size and dimensions (bounds given by the caller)" do
    test "the maximum size is the caller's" do
      too_big = png() <> :binary.copy(<<0>>, 2_097_152)
      assert {:error, :too_large} = sanitize(too_big)

      # sous la borne d'un autre appelant (5 Mo) : seule la structure compte (octets après IEND ignorés)
      assert {:ok, %{width: 64}} = sanitize(too_big, max_bytes: 5_242_880, sides: 1..8192)
    end

    test "pixels per side, read from the headers of every format" do
      assert {:ok, %{width: 2048, height: 64}} = sanitize(png(2048, 64))
      assert {:error, :dimensions} = sanitize(png(63, 64))
      assert {:error, :dimensions} = sanitize(png(64, 2049))
      assert {:ok, %{width: 1, height: 1}} = sanitize(png(1, 1), max_bytes: 1000, sides: 1..8192)

      assert {:ok, %{width: 300, height: 200}} = sanitize(jpeg(300, 200))
      assert {:error, :dimensions} = sanitize(jpeg(4000, 3000))

      assert {:ok, %{width: 640, height: 480}} = sanitize(webp_vp8l(640, 480))
      assert {:ok, %{width: 120, height: 90}} = sanitize(webp_vp8(120, 90))
      assert {:ok, %{width: 256, height: 128}} = sanitize(webp_vp8x(256, 128))
      assert {:error, :dimensions} = sanitize(webp_vp8l(32, 32))
    end

    test "truncated or inconsistent files are refused" do
      png = png()
      assert {:error, :malformed} = sanitize(binary_part(png, 0, byte_size(png) - 20))
      # premier chunk autre qu'IHDR
      assert {:error, :malformed} =
               sanitize(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> png_chunk("IEND", ""))

      # JPEG sans en-tête de trame (SOF), ou coupé au milieu d'un segment
      assert {:error, :malformed} =
               sanitize(IO.iodata_to_binary([<<0xFF, 0xD8>>, jfif(), scan(), <<0xFF, 0xD9>>]))

      assert {:error, :malformed} = sanitize(binary_part(jpeg(), 0, 30))
      assert {:error, :malformed} = sanitize(riff([{"XMP ", "no image chunk"}]))
    end
  end

  describe "metadata removal" do
    test "PNG: text chunks, eXIf and tIME are removed; the image chunks are kept intact" do
      original =
        png(64, 64, [
          {"tEXt", "Author\0Lyra GPS-SECRET"},
          {"zTXt", "Comment\0\0" <> :zlib.compress("secret")},
          {"iTXt", "XML:com.adobe.xmp\0\0\0\0\0<x:xmpmeta>XMP-SECRET</x:xmpmeta>"},
          {"eXIf", "MM\0*GPS-SECRET"},
          {"tIME", <<2026::16, 11, 24, 9, 30, 0>>},
          {"pHYs", <<2835::32, 2835::32, 1>>},
          {"prVt", "private chunk"}
        ])

      assert {:ok, %{data: clean}} = sanitize(original)
      assert png_chunk_types(clean) == ~w(IHDR pHYs IDAT IEND)
      refute clean =~ "SECRET"
      # les pixels (IDAT) et l'en-tête sont recopiés octet pour octet
      assert clean == png(64, 64, [{"pHYs", <<2835::32, 2835::32, 1>>}])
    end

    test "JPEG: EXIF (GPS), XMP, ICC and comments are removed; JFIF, Adobe and the scan are kept" do
      original =
        jpeg(64, 64, [jfif(), exif_gps(), xmp_jpeg(), icc_jpeg(), comment_jpeg(), adobe()])

      assert {:ok, %{data: clean}} = sanitize(original)
      refute clean =~ "Exif"
      refute clean =~ "SECRET"
      refute clean =~ "ICC_PROFILE"
      assert clean =~ "JFIF" and clean =~ "Adobe"
      assert clean == jpeg(64, 64, [jfif(), adobe()])
      # données compressées (FF00 échappé, RST) recopiées telles quelles
      assert :binary.match(clean, scan_data()) != :nomatch
    end

    test "JPEG: metadata between the scans of a progressive image is removed too" do
      progressive =
        IO.iodata_to_binary([
          <<0xFF, 0xD8>>,
          jfif(),
          segment(0xC2, <<8, 64::16, 64::16, 1, 1, 0x11, 0>>),
          scan(),
          exif_gps(),
          segment(0xC4, <<0, 0::128>>),
          scan(),
          <<0xFF, 0xD9>>
        ])

      assert {:ok, %{data: clean, width: 64}} = sanitize(progressive)
      refute clean =~ "SECRET"
      assert length(:binary.matches(clean, scan_data())) == 2
    end

    test "WebP: EXIF and XMP chunks are removed, VP8X flags and RIFF size are rewritten" do
      assert {:ok, %{data: clean}} = sanitize(webp_vp8x(256, 128))
      assert webp_chunk_types(clean) == ~w(VP8X VP8L)
      refute clean =~ "SECRET"
      <<"RIFF", size::little-32, "WEBP", _::binary>> = clean
      assert size == byte_size(clean) - 8
      <<_::binary-size(20), flags, _::binary>> = clean
      assert Bitwise.band(flags, 0x0C) == 0
    end
  end
end
