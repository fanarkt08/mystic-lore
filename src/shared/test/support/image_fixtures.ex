defmodule MlShared.ImageFixtures do
  @moduledoc """
  Fichiers construits octet par octet pour les tests d'images (shared, accounts, social) : PNG décodable,
  JPEG et WebP valides avec les métadonnées voulues, et un PDF minimal.
  """
  import Bitwise

  ## PDF

  @doc "PDF minimal d'une page (en-tête `%PDF-`), complété par un commentaire jusqu'à `size` octets exactement."
  def pdf(size \\ 0) do
    body =
      "%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n" <>
        "2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n" <>
        "3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >> endobj\n" <>
        "trailer << /Root 1 0 R >>\n"

    padding = max(size - byte_size(body) - 7, 0)
    body <> "%" <> :binary.copy("x", padding) <> "\n%%EOF"
  end

  ## PNG

  def png(width \\ 64, height \\ 64, extra \\ []) do
    row = <<0>> <> :binary.copy(<<120, 84, 232>>, width)
    idat = :zlib.compress(:binary.copy(row, height))
    ihdr = <<width::32, height::32, 8, 2, 0, 0, 0>>

    IO.iodata_to_binary([
      <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>,
      png_chunk("IHDR", ihdr),
      Enum.map(extra, fn {type, data} -> png_chunk(type, data) end),
      png_chunk("IDAT", idat),
      png_chunk("IEND", "")
    ])
  end

  def png_chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>

  @doc "Types des chunks d'un PNG, dans l'ordre."
  def png_chunk_types(<<_sig::binary-size(8), rest::binary>>), do: chunk_types(rest, [])

  defp chunk_types(<<>>, acc), do: Enum.reverse(acc)

  defp chunk_types(
         <<len::32, type::binary-size(4), _::binary-size(len), _::32, rest::binary>>,
         acc
       ),
       do: chunk_types(rest, [type | acc])

  ## JPEG (SOI, segments donnés, DQT, SOF0, DHT, SOS + données compressées avec FF00 et RST, EOI)

  def jpeg(width \\ 64, height \\ 64, segments \\ [jfif()]) do
    IO.iodata_to_binary([
      <<0xFF, 0xD8>>,
      segments,
      segment(0xDB, <<0>> <> :binary.copy(<<1>>, 64)),
      segment(0xC0, <<8, height::16, width::16, 1, 1, 0x11, 0>>),
      segment(0xC4, <<0, 0::128>>),
      scan(),
      <<0xFF, 0xD9>>
    ])
  end

  @doc "Données compressées d'un balayage (avec un octet FF échappé et un marqueur RST)."
  def scan_data, do: <<0x12, 0x34, 0xFF, 0x00, 0x56, 0xFF, 0xD0, 0x78, 0x9A>>

  def scan, do: [segment(0xDA, <<1, 1, 0, 0, 63, 0>>), scan_data()]

  def segment(marker, payload), do: <<0xFF, marker, byte_size(payload) + 2::16, payload::binary>>

  def jfif, do: segment(0xE0, <<"JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0>>)
  def adobe, do: segment(0xEE, <<"Adobe", 0, 100, 0, 0, 0, 0, 1>>)

  @doc "APP1 EXIF minimal avec un IFD GPS (latitude 48° 51' N) et un marqueur texte reconnaissable."
  def exif_gps do
    tiff =
      <<"MM", 42::16, 8::32, 1::16, 0x8825::16, 4::16, 1::32, 26::32, 0::32>> <>
        <<1::16, 0x0001::16, 2::16, 2::32, "N", 0, 0, 0, 0::32>> <> "GPS-SECRET-48.85N"

    segment(0xE1, "Exif" <> <<0, 0>> <> tiff)
  end

  def xmp_jpeg,
    do:
      segment(
        0xE1,
        "http://ns.adobe.com/xap/1.0/" <> <<0>> <> "<x:xmpmeta>XMP-SECRET</x:xmpmeta>"
      )

  def icc_jpeg, do: segment(0xE2, "ICC_PROFILE" <> <<0, 1, 1>> <> "ICC-DATA")
  def comment_jpeg, do: segment(0xFE, "COMMENT-SECRET")

  ## WebP

  def webp_vp8l(width \\ 64, height \\ 64, extra \\ []) do
    bits = width - 1 ||| (height - 1) <<< 14
    riff([{"VP8L", <<0x2F, bits::little-32, 0, 0, 0>>} | extra])
  end

  def webp_vp8(width \\ 64, height \\ 64) do
    riff([{"VP8 ", <<0, 0, 0, 0x9D, 0x01, 0x2A, width::little-16, height::little-16, 0, 0>>}])
  end

  @doc "WebP étendu (VP8X) : drapeaux EXIF et XMP posés, chunks EXIF et XMP présents."
  def webp_vp8x(width \\ 64, height \\ 64) do
    vp8x = <<0x0C, 0::24, width - 1::little-24, height - 1::little-24>>
    bits = width - 1 ||| (height - 1) <<< 14

    riff([
      {"VP8X", vp8x},
      {"VP8L", <<0x2F, bits::little-32, 0, 0, 0>>},
      {"EXIF", "Exif-GPS-SECRET"},
      {"XMP ", "<x:xmpmeta>XMP-SECRET</x:xmpmeta>"}
    ])
  end

  def riff(chunks) do
    body =
      for {type, data} <- chunks, into: <<>> do
        pad = if rem(byte_size(data), 2) == 1, do: <<0>>, else: <<>>
        <<type::binary, byte_size(data)::little-32, data::binary, pad::binary>>
      end

    <<"RIFF", byte_size(body) + 4::little-32, "WEBP", body::binary>>
  end

  @doc "Types des chunks d'un WebP, dans l'ordre."
  def webp_chunk_types(<<"RIFF", _::little-32, "WEBP", rest::binary>>), do: riff_types(rest, [])

  defp riff_types(<<>>, acc), do: Enum.reverse(acc)

  defp riff_types(<<type::binary-size(4), size::little-32, rest::binary>>, acc) do
    pad = rem(size, 2)
    <<_::binary-size(^size), _::binary-size(^pad), rest::binary>> = rest
    riff_types(rest, [type | acc])
  end
end
