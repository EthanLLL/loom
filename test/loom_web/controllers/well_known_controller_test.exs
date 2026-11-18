defmodule LoomWeb.WellKnownControllerTest do
  # Sets application env, so not async.
  use LoomWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:loom, :ios_apps)
    on_exit(fn -> Application.put_env(:loom, :ios_apps, previous) end)
  end

  test "names the iOS apps that may use this Loom's passkeys", %{conn: conn} do
    Application.put_env(:loom, :ios_apps, ["ABCDE12345.com.example.loom"])

    assert %{"webcredentials" => %{"apps" => ["ABCDE12345.com.example.loom"]}} =
             conn |> get("/.well-known/apple-app-site-association") |> json_response(200)
  end

  test "is not there without one", %{conn: conn} do
    Application.put_env(:loom, :ios_apps, [])
    assert conn |> get("/.well-known/apple-app-site-association") |> response(404)
  end
end
