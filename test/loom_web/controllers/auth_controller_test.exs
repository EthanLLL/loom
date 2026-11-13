defmodule LoomWeb.AuthControllerTest do
  # The app's own `Loom.Auth`, so not async; logins made here are revoked again.
  use LoomWeb.ConnCase, async: false

  test "a token from before logins is swapped for one of its own", %{conn: conn} do
    legacy = Phoenix.Token.sign(LoomWeb.Endpoint, "loom auth token", %{ok: true})

    body =
      conn
      |> put_req_header("authorization", "Bearer " <> legacy)
      |> put_req_header(
        "user-agent",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 27_1 like Mac OS X) Safari/604.1"
      )
      |> get("/api/auth")
      |> json_response(200)

    assert %{"current" => "legacy", "token" => token} = body
    assert {:ok, id} = Loom.Auth.verify_token(token)
    assert %{name: "iPhone · Safari"} = Enum.find(Loom.Auth.overview().logins, &(&1.id == id))

    body =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get("/api/auth")
      |> json_response(200)

    assert body["current"] == id
    refute Map.has_key?(body, "token")

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> delete("/api/auth/logins/#{id}")
    |> response(204)

    assert build_conn()
           |> put_req_header("authorization", "Bearer " <> token)
           |> get("/api/auth")
           |> response(401)
  end

  test "the sign-in page learns what to offer", %{conn: conn} do
    assert %{"passkey" => _, "totp" => _} = conn |> get("/api/auth/options") |> json_response(200)
  end
end
