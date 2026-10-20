defmodule LoomWeb.PushControllerTest do
  # The app's own `Loom.Push`, so not async, and every subscription made here is
  # removed again: a turn ending in another test would otherwise try to send to it.
  use LoomWeb.ConnCase, async: false

  @endpoint_url "https://push.example/controller-test"

  setup %{conn: conn} do
    on_exit(fn -> Loom.Push.unsubscribe(@endpoint_url) end)
    authed = put_req_header(conn, "authorization", "Bearer " <> Loom.Auth.mint_token())
    {:ok, authed: authed}
  end

  test "gives the key, keeps a subscription, and forgets it", %{authed: conn} do
    assert %{"key" => key} = conn |> get("/api/push") |> json_response(200)
    assert key == Loom.Push.public_key()

    subscription = %{
      "endpoint" => @endpoint_url,
      "keys" => %{"p256dh" => "BCVxsr7N_eNgVRqvHtD0zQ", "auth" => "BTBZMqHH6r4Tts7J_aSIgg"}
    }

    conn
    |> post("/api/push/subscriptions", %{
      subscription: subscription,
      origin: "https://loom.example"
    })
    |> response(204)

    assert Enum.any?(Loom.Push.list(), &(&1.endpoint == @endpoint_url))

    conn |> delete("/api/push/subscriptions", %{endpoint: @endpoint_url}) |> response(204)
    refute Enum.any?(Loom.Push.list(), &(&1.endpoint == @endpoint_url))
  end

  test "refuses a bad subscription", %{authed: conn} do
    conn
    |> post("/api/push/subscriptions", %{subscription: %{endpoint: "x"}, origin: "https://l"})
    |> json_response(422)
  end

  test "needs the token", %{conn: conn} do
    assert conn |> get("/api/push") |> response(401)
  end
end
