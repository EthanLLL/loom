defmodule Loom.AuthTest do
  use ExUnit.Case, async: true

  alias Loom.Auth
  alias Loom.Auth.Totp

  @info %{name: "iPhone · Safari", ip: "203.0.113.7"}
  @origin "https://loom.example"

  setup do
    dir = Path.join(System.tmp_dir!(), "loom-auth-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "auth.json")
    {:ok, server: start_auth(path), path: path}
  end

  defp start_auth(path) do
    {:ok, pid} = Auth.start_link(path: path, name: nil)
    pid
  end

  defp current_code(secret) do
    {:ok, key} = Base.decode32(secret, padding: false)
    Totp.code(key, Totp.step())
  end

  defp setup_totp(server) do
    secret = Auth.totp_begin(server)
    {:ok, codes} = Auth.totp_confirm(current_code(secret), server)
    {secret, codes}
  end

  test "checks the configured password" do
    assert Auth.valid_password?("test-password")
    refute Auth.valid_password?("wrong")
    refute Auth.valid_password?("")
    refute Auth.valid_password?(nil)
  end

  test "the password alone signs in until an authenticator is set up", %{server: s} do
    assert %{passkey: false, totp: false} = Auth.options(s)
    assert {:ok, token} = Auth.password_login("test-password", nil, @info, s)
    assert {:ok, id} = Auth.verify_token(token, s)

    assert [%{id: ^id, name: "iPhone · Safari", method: "password", ip: "203.0.113.7"}] =
             Auth.overview(s).logins

    assert {:error, :invalid} = Auth.password_login("wrong", nil, @info, s)
  end

  test "after setup the password needs a code, each good once", %{server: s} do
    {secret, _codes} = setup_totp(s)
    assert %{totp: true} = Auth.options(s)

    assert {:error, :invalid} = Auth.password_login("test-password", nil, @info, s)
    # The code that confirmed the setup was spent there.
    assert {:error, :invalid} =
             Auth.password_login("test-password", current_code(secret), @info, s)

    {:ok, key} = Base.decode32(secret, padding: false)
    next = Totp.code(key, Totp.step() + 1)
    assert {:ok, _} = Auth.password_login("test-password", next, @info, s)
    assert {:error, :invalid} = Auth.password_login("test-password", next, @info, s)
    assert {:error, :invalid} = Auth.password_login("wrong", next, @info, s)
  end

  test "a recovery code stands in for the code, once", %{server: s} do
    {_secret, [code | _] = codes} = setup_totp(s)
    assert length(codes) == 8

    assert {:ok, _} = Auth.password_login("test-password", String.upcase(code), @info, s)
    assert {:error, :invalid} = Auth.password_login("test-password", code, @info, s)
    assert Auth.overview(s).totp.recovery_left == 7
  end

  test "a wrong code does not confirm the setup", %{server: s} do
    Auth.totp_begin(s)
    assert {:error, :invalid} = Auth.totp_confirm("000000", s)
    assert %{totp: false} = Auth.options(s)
  end

  test "five failures lock the password way in", %{server: s} do
    for _ <- 1..5, do: assert({:error, :invalid} = Auth.password_login("nope", nil, @info, s))
    assert {:error, :locked} = Auth.password_login("test-password", nil, @info, s)
  end

  test "a token from before logins works until an authenticator is set up", %{server: s} do
    legacy = Phoenix.Token.sign(LoomWeb.Endpoint, "loom auth token", %{ok: true})
    assert {:ok, :legacy} = Auth.verify_token(legacy, s)

    assert {:ok, token} = Auth.upgrade(@info, s)
    assert {:ok, _id} = Auth.verify_token(token, s)

    setup_totp(s)
    assert {:error, :legacy} = Auth.verify_token(legacy, s)
    assert {:ok, _id} = Auth.verify_token(token, s)
  end

  test "a revoked login is signed out", %{server: s} do
    token = Auth.mint_token("Mac · Chrome", s)
    {:ok, id} = Auth.verify_token(token, s)
    :ok = Auth.revoke(id, s)
    assert {:error, :revoked} = Auth.verify_token(token, s)
    assert {:error, _} = Auth.verify_token("garbage", s)
    assert {:error, :missing} = Auth.verify_token(nil, s)
  end

  test "a login unused for 14 days lapses; one in use is kept", %{server: s, path: path} do
    token = Auth.mint_token("PC", s)
    {:ok, id} = Auth.verify_token(token, s)
    fresh = Auth.mint_token("Mac", s)
    GenServer.stop(s)

    old = DateTime.utc_now() |> DateTime.add(-15, :day) |> DateTime.to_iso8601()
    data = path |> File.read!() |> Jason.decode!()

    logins =
      Enum.map(data["logins"], fn l ->
        if l["id"] == id, do: %{l | "last_seen_at" => old}, else: l
      end)

    File.write!(path, Jason.encode!(%{data | "logins" => logins}))

    s = start_auth(path)
    assert {:error, :expired} = Auth.verify_token(token, s)
    assert {:ok, _} = Auth.verify_token(fresh, s)
    assert [%{name: "Mac"}] = Auth.overview(s).logins
  end

  describe "passkeys" do
    setup do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      {:ECPrivateKey, _, _, curve, point, _} = key

      {:SubjectPublicKeyInfo, der, _} =
        :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {{:ECPoint, point}, curve})

      {:ok, key: key, spki: der}
    end

    defp b64(bin), do: Base.url_encode64(bin, padding: false)

    defp client_data(type, challenge, origin \\ @origin),
      do: Jason.encode!(%{type: type, challenge: challenge, origin: origin})

    defp auth_data(rp_id \\ "loom.example", flags \\ 0x05),
      do: :crypto.hash(:sha256, rp_id) <> <<flags, 0::32>>

    defp register(s, spki) do
      challenge = Auth.challenge(:register, s)

      Auth.register_passkey(
        %{
          "id" => "cred-1",
          "client_data" => b64(client_data("webauthn.create", challenge)),
          "authenticator_data" => b64(auth_data()),
          "public_key" => b64(spki)
        },
        %{name: "iPhone · Safari", ip: nil},
        s
      )
    end

    defp assertion(s, key, opts \\ []) do
      challenge = Keyword.get_lazy(opts, :challenge, fn -> Auth.challenge(:login, s) end)
      cd = client_data("webauthn.get", challenge, Keyword.get(opts, :origin, @origin))
      ad = auth_data("loom.example", Keyword.get(opts, :flags, 0x05))
      sig = :public_key.sign(ad <> :crypto.hash(:sha256, cd), :sha256, key)

      %{
        "id" => "cred-1",
        "client_data" => b64(cd),
        "authenticator_data" => b64(ad),
        "signature" => b64(sig)
      }
    end

    test "register, then sign in with a fingerprint", %{server: s, key: key, spki: spki} do
      assert {:ok, %{id: "cred-1", rp_id: "loom.example"}} = register(s, spki)
      assert %{passkey: true} = Auth.options(s)

      assert {:ok, token} = Auth.passkey_login(assertion(s, key), @info, s)
      assert {:ok, _} = Auth.verify_token(token, s)
      assert [%{method: "passkey"}] = Auth.overview(s).logins

      assert {:ok, _} =
               Auth.passkey_login(assertion(s, key), %{@info | name: "Windows · Edge"}, s)

      assert %{method: "passkey made on iPhone · Safari"} =
               Enum.find(Auth.overview(s).logins, &(&1.name == "Windows · Edge"))
    end

    test "works with the password locked out", %{server: s, key: key, spki: spki} do
      {:ok, _} = register(s, spki)
      for _ <- 1..5, do: Auth.password_login("nope", nil, @info, s)
      assert {:ok, _} = Auth.passkey_login(assertion(s, key), @info, s)
    end

    test "refuses a reused challenge, another site, no user check, another key",
         %{server: s, key: key, spki: spki} do
      {:ok, _} = register(s, spki)

      challenge = Auth.challenge(:login, s)
      assert {:ok, _} = Auth.passkey_login(assertion(s, key, challenge: challenge), @info, s)

      assert {:error, :challenge} =
               Auth.passkey_login(assertion(s, key, challenge: challenge), @info, s)

      assert {:error, :origin} =
               Auth.passkey_login(assertion(s, key, origin: "https://evil.example"), @info, s)

      assert {:error, :not_verified} =
               Auth.passkey_login(assertion(s, key, flags: 0x01), @info, s)

      other = :public_key.generate_key({:namedCurve, :secp256r1})
      assert {:error, :signature} = Auth.passkey_login(assertion(s, other), @info, s)

      # A registration challenge cannot sign in.
      reg = Auth.challenge(:register, s)

      assert {:error, :challenge} =
               Auth.passkey_login(assertion(s, key, challenge: reg), @info, s)
    end

    test "an RSA key, as Windows Hello may make", %{server: s} do
      key = :public_key.generate_key({:rsa, 2048, 65537})
      {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = key

      {:SubjectPublicKeyInfo, der, _} =
        :public_key.pem_entry_encode(:SubjectPublicKeyInfo, {:RSAPublicKey, n, e})

      {:ok, _} = register(s, der)
      assert {:ok, _} = Auth.passkey_login(assertion(s, key), @info, s)
    end

    test "survives a restart", %{server: s, key: key, spki: spki, path: path} do
      {:ok, _} = register(s, spki)
      GenServer.stop(s)
      s = start_auth(path)
      assert {:ok, _} = Auth.passkey_login(assertion(s, key), @info, s)
    end
  end
end
