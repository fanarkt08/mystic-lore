defmodule MlBilling.SignatureTest do
  use ExUnit.Case, async: true
  alias MlBilling.Signature

  @secret "whsec_unit"
  @body ~s({"id":"evt_1","type":"invoice.paid"})

  test "a valid signature is accepted, also among several v1 candidates (secret rotation)" do
    header = Signature.header(@body, @secret)
    assert :ok = Signature.verify(@body, header, @secret)

    [t, v1] = String.split(header, ",")
    rotated = Enum.join([t, "v1=" <> String.duplicate("0", 64), v1, "v0=legacy"], ",")
    assert :ok = Signature.verify(@body, rotated, @secret)
  end

  test "an invalid signature is rejected: tampered body, other secret, malformed header" do
    header = Signature.header(@body, @secret)
    assert {:error, :invalid_signature} = Signature.verify(@body <> " ", header, @secret)
    assert {:error, :invalid_signature} = Signature.verify(@body, header, "whsec_other")

    for bad <- [nil, "", "garbage", "t=abc,v1=00", "v1=" <> String.duplicate("0", 64)] do
      assert {:error, :invalid_signature} = Signature.verify(@body, bad, @secret)
    end

    for missing_secret <- [nil, ""] do
      assert {:error, :invalid_signature} = Signature.verify(@body, header, missing_secret)
    end
  end

  test "an expired (or far-future) timestamp is rejected beyond 300 s" do
    now = System.os_time(:second)

    assert :ok =
             Signature.verify(@body, Signature.header(@body, @secret, now - 300), @secret, now)

    for t <- [now - 301, now + 301] do
      assert {:error, :expired_signature} =
               Signature.verify(@body, Signature.header(@body, @secret, t), @secret, now)
    end
  end
end
