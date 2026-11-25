defmodule MlShared.Image do
  @moduledoc """
  Vérifie et nettoie les images téléversées, en reconnaissant le type à ses octets et jamais à l'extension.
  Les métadonnées (EXIF, GPS, XMP, textes) sont retirées sans ré-encoder l'image.
  """
  import Bitwise

  @png_signature <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>
  @png_kept ~w(IHDR PLTE IDAT IEND tRNS gAMA cHRM sRGB iCCP sBIT bKGD pHYs)

  @doc "Valide une image (`max_bytes`, `sides`) et renvoie sa version nettoyée avec son type et ses dimensions."
  def sanitize(bytes, opts) when is_binary(bytes) do
    sides = Keyword.fetch!(opts, :sides)

    with :ok <- check_size(bytes, Keyword.fetch!(opts, :max_bytes)),
         {:ok, type, ext} <- detect(bytes),
         {:ok, data, {width, height}} <- strip(ext, bytes),
         true <- (width in sides and height in sides) || {:error, :dimensions} do
      {:ok, %{type: type, ext: ext, width: width, height: height, data: data}}
    end
  end

  defp check_size(bytes, max) when byte_size(bytes) > max, do: {:error, :too_large}
  defp check_size(_bytes, _max), do: :ok

  @doc "Type d'après les octets magiques : `{:ok, mime, extension}` ou `{:error, :unsupported}`."
  def detect(<<@png_signature, _::binary>>), do: {:ok, "image/png", "png"}
  def detect(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg", "jpg"}
  def detect(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp", "webp"}
  def detect(_bytes), do: {:error, :unsupported}

  # Toute incohérence (longueur hors du fichier, segment tronqué, ordre invalide) : fichier invalide.
  defp strip(ext, bytes) do
    case ext do
      "png" -> png(bytes)
      "jpg" -> jpeg(bytes)
      "webp" -> webp(bytes)
    end
  rescue
    _ in [MatchError, FunctionClauseError, CaseClauseError, ArgumentError] ->
      {:error, :malformed}
  end

  ## PNG : signature, puis chunks `longueur (4) · type (4) · données · CRC (4)` ; IHDR d'abord, IEND à la fin.

  defp png(<<@png_signature, rest::binary>>) do
    {chunks, dims} = png_chunks(rest, [], nil, false)
    {:ok, IO.iodata_to_binary([@png_signature | chunks]), dims}
  end

  defp png_chunks(bin, acc, dims, idat?) do
    <<len::32, type::binary-size(4), data::binary-size(len), crc::32, rest::binary>> = bin
    chunk = <<len::32, type::binary, data::binary, crc::32>>

    case {type, dims} do
      {"IHDR", nil} ->
        <<w::32, h::32, _::binary>> = data
        png_chunks(rest, [chunk], {w, h}, false)

      {"IEND", {_, _}} when idat? ->
        {Enum.reverse([chunk | acc]), dims}

      {type, {_, _}} when type not in ["IHDR", "IEND"] ->
        acc = if type in @png_kept, do: [chunk | acc], else: acc
        png_chunks(rest, acc, dims, idat? or type == "IDAT")
    end
  end

  ## JPEG : marqueurs `FF xx` ; segments `FF xx · longueur (2, incluse) · données` jusqu'à SOS, puis données
  ## compressées (où `FF 00` et `FF D0..D7` ne sont pas des marqueurs) jusqu'au marqueur suivant ou EOI.

  defp jpeg(<<0xFF, 0xD8, rest::binary>>) do
    case jpeg_segments(rest, [], nil) do
      {segments, {_, _} = dims} -> {:ok, IO.iodata_to_binary([<<0xFF, 0xD8>> | segments]), dims}
      {_segments, nil} -> {:error, :malformed}
    end
  end

  # bourrage : plusieurs FF avant un marqueur
  defp jpeg_segments(<<0xFF, 0xFF, rest::binary>>, acc, dims),
    do: jpeg_segments(<<0xFF, rest::binary>>, acc, dims)

  defp jpeg_segments(<<0xFF, 0xD9, _::binary>>, acc, dims),
    do: {Enum.reverse([<<0xFF, 0xD9>> | acc]), dims}

  defp jpeg_segments(<<0xFF, marker, len::16, _::binary>> = bin, acc, dims) when len >= 2 do
    size = len + 2
    <<segment::binary-size(^size), rest::binary>> = bin
    <<_::32, payload::binary>> = segment
    dims = dims || sof_dimensions(marker, payload)

    if marker == 0xDA do
      {scan, rest} = entropy_data(rest, 0)
      jpeg_segments(rest, [scan, segment | acc], dims)
    else
      acc = if keep_jpeg_segment?(marker, payload), do: [segment | acc], else: acc
      jpeg_segments(rest, acc, dims)
    end
  end

  # APP0 « JFIF » et APP14 « Adobe » seulement : les autres APPn (EXIF, XMP, ICC…) et COM sont retirés
  defp keep_jpeg_segment?(0xE0, <<"JFIF", 0, _::binary>>), do: true
  defp keep_jpeg_segment?(0xEE, <<"Adobe", _::binary>>), do: true
  defp keep_jpeg_segment?(marker, _payload) when marker in 0xE0..0xEF or marker == 0xFE, do: false
  defp keep_jpeg_segment?(_marker, _payload), do: true

  # SOF0..SOF15 sauf DHT (C4), JPG (C8) et DAC (CC) : précision (1), hauteur (2), largeur (2)
  defp sof_dimensions(marker, <<_precision, h::16, w::16, _::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC],
       do: {w, h}

  defp sof_dimensions(_marker, _payload), do: nil

  # Données compressées : jusqu'au premier `FF` suivi d'un vrai marqueur (`{données, reste}`).
  defp entropy_data(bin, from) do
    {pos, 1} = :binary.match(bin, <<0xFF>>, scope: {from, byte_size(bin) - from})

    case bin do
      <<_::binary-size(^pos), 0xFF, next, _::binary>> when next == 0 or next in 0xD0..0xD7 ->
        entropy_data(bin, pos + 2)

      <<_::binary-size(^pos), 0xFF, 0xFF, _::binary>> ->
        entropy_data(bin, pos + 1)

      <<scan::binary-size(^pos), 0xFF, _marker, _::binary>> ->
        {scan, binary_part(bin, pos, byte_size(bin) - pos)}
    end
  end

  ## WebP : `RIFF · taille (LE) · WEBP` puis chunks `type (4) · taille (LE) · données · bourrage pair`.

  defp webp(<<"RIFF", _size::little-32, "WEBP", rest::binary>>) do
    chunks = webp_chunks(rest, [])
    dims = webp_dimensions(chunks)

    body =
      for {type, data} <- chunks, type not in ["EXIF", "XMP "] do
        data = if type == "VP8X", do: clear_vp8x_metadata(data), else: data
        [type, <<byte_size(data)::little-32>>, data, if(odd?(data), do: <<0>>, else: "")]
      end
      |> IO.iodata_to_binary()

    {:ok, <<"RIFF", byte_size(body) + 4::little-32, "WEBP", body::binary>>, dims}
  end

  defp webp_chunks(<<>>, acc), do: Enum.reverse(acc)

  defp webp_chunks(<<type::binary-size(4), size::little-32, rest::binary>>, acc) do
    <<data::binary-size(^size), rest::binary>> = rest
    # octet de bourrage d'un chunk impair (parfois absent à la fin du fichier)
    rest =
      if odd?(data) and rest != <<>>, do: binary_part(rest, 1, byte_size(rest) - 1), else: rest

    webp_chunks(rest, [{type, data} | acc])
  end

  defp odd?(data), do: (byte_size(data) &&& 1) == 1

  # VP8X : drapeaux (ICC 0x20, alpha 0x10, EXIF 0x08, XMP 0x04, animation 0x02), 3 octets réservés, puis
  # largeur - 1 et hauteur - 1 sur 24 bits (petit-boutiste).
  defp clear_vp8x_metadata(<<flags, rest::binary>>), do: <<flags &&& 0xF3, rest::binary>>

  defp webp_dimensions([{"VP8X", <<_flags, _::24, w::little-24, h::little-24, _::binary>>} | _]),
    do: {w + 1, h + 1}

  # VP8 (avec perte) : en-tête de trame (3), code de début 9D 01 2A, largeur et hauteur sur 14 bits
  defp webp_dimensions([
         {"VP8 ", <<_frame::24, 0x9D, 0x01, 0x2A, w::little-16, h::little-16, _::binary>>} | _
       ]),
       do: {w &&& 0x3FFF, h &&& 0x3FFF}

  # VP8L (sans perte) : signature 0x2F puis largeur - 1 et hauteur - 1 sur 14 bits
  defp webp_dimensions([{"VP8L", <<0x2F, bits::little-32, _::binary>>} | _]),
    do: {(bits &&& 0x3FFF) + 1, (bits >>> 14 &&& 0x3FFF) + 1}
end
