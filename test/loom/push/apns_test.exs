defmodule Loom.Push.APNsTest do
  use ExUnit.Case, async: true

  alias Loom.Push.APNs

  test "a provider token is an ES256 JWT from the team, under the key's id" do
    key = :public_key.generate_key({:namedCurve, :secp256r1})
    file = Path.join(System.tmp_dir!(), "apns-#{System.unique_integer([:positive])}.p8")

    File.write!(
      file,
      :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])
    )

    on_exit(fn -> File.rm(file) end)

    token =
      APNs.sign(%{key_file: file, key_id: "KEY0000001", team_id: "TEAM000001"}, 1_800_000_000)

    [header, claims, signature] = String.split(token, ".")
    decode = &Base.url_decode64!(&1, padding: false)

    assert %{"alg" => "ES256", "kid" => "KEY0000001"} = Jason.decode!(decode.(header))
    assert %{"iss" => "TEAM000001", "iat" => 1_800_000_000} = Jason.decode!(decode.(claims))

    <<r::256, s::256>> = decode.(signature)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})
    {:ECPrivateKey, _, _, params, public, _} = key
    assert :public_key.verify(header <> "." <> claims, :sha256, der, {{:ECPoint, public}, params})
  end

  test "an endpoint is Apple's URL for a hex token, in its environment" do
    assert {:ok, "https://api.push.apple.com/3/device/ab" <> _} =
             APNs.endpoint("AB" <> String.duplicate("0", 62), false)

    assert {:ok, "https://api.sandbox.push.apple.com/3/device/" <> _} =
             APNs.endpoint(String.duplicate("0", 64), true)

    assert :error = APNs.endpoint("../x", false)
    assert :error = APNs.endpoint(String.duplicate("0", 64), "yes")
  end
end
