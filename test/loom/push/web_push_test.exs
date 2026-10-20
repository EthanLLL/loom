defmodule Loom.Push.WebPushTest do
  use ExUnit.Case, async: true

  alias Loom.Push.WebPush

  # The browser's side of RFC 8291, so the test checks the message opens with
  # what the browser holds rather than restating the sender's arithmetic.
  defp decrypt(body, ua_public, ua_private, auth) do
    <<salt::binary-16, rs::32, idlen::8, as_public::binary-size(idlen), rest::binary>> = body
    assert rs == 4096
    shared = :crypto.compute_key(:ecdh, as_public, ua_private, :prime256v1)
    prk_key = :crypto.mac(:hmac, :sha256, auth, shared)

    ikm =
      :crypto.mac(
        :hmac,
        :sha256,
        prk_key,
        "WebPush: info" <> <<0>> <> ua_public <> as_public <> <<1>>
      )

    prk = :crypto.mac(:hmac, :sha256, salt, ikm)

    <<cek::binary-16, _::binary>> =
      :crypto.mac(:hmac, :sha256, prk, "Content-Encoding: aes128gcm" <> <<0, 1>>)

    <<nonce::binary-12, _::binary>> =
      :crypto.mac(:hmac, :sha256, prk, "Content-Encoding: nonce" <> <<0, 1>>)

    size = byte_size(rest) - 16
    <<ciphertext::binary-size(^size), tag::binary-16>> = rest
    :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false)
  end

  test "a message opens with the browser's keys" do
    {ua_public, ua_private} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)

    body = WebPush.encrypt(~s({"hello":"世界"}), ua_public, auth)

    # The trailing 0x02 is the last-record delimiter.
    assert decrypt(body, ua_public, ua_private, auth) == ~s({"hello":"世界"}) <> <<2>>
  end

  test "matches the worked example in RFC 8291 §5" do
    d = &WebPush.decode!/1

    ua_public =
      d.(
        "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
      )

    as_public =
      d.(
        "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
      )

    as_private = d.("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")
    auth = d.("BTBZMqHH6r4Tts7J_aSIgg")
    salt = d.("DGv6ra1nlYgDCS1FRnbzlw")

    body =
      WebPush.encrypt("When I grow up, I want to be a watermelon", ua_public, auth,
        keys: {as_public, as_private},
        salt: salt
      )

    assert WebPush.b64(body) ==
             "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
  end

  test "the VAPID token is for the push service's origin and verifies with the public key" do
    keys = WebPush.generate_keys()

    header =
      WebPush.authorization(
        "https://web.push.apple.com/QGuQ/abc",
        keys,
        "https://loom.example",
        1_000
      )

    [_, jwt, k] = Regex.run(~r/^vapid t=([^,]+), k=(.+)$/, header)
    assert WebPush.decode!(k) == keys.public

    [h, c, sig] = String.split(jwt, ".")
    assert Jason.decode!(WebPush.decode!(h)) == %{"typ" => "JWT", "alg" => "ES256"}

    assert Jason.decode!(WebPush.decode!(c)) == %{
             "aud" => "https://web.push.apple.com",
             "exp" => 1_000 + 12 * 3600,
             "sub" => "https://loom.example"
           }

    <<r::256, s::256>> = WebPush.decode!(sig)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    assert :crypto.verify(:ecdsa, :sha256, h <> "." <> c, der, [keys.public, :prime256v1])
  end
end
