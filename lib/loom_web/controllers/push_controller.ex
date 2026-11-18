defmodule LoomWeb.PushController do
  @moduledoc """
  Turning notifications on and off for one device; see `Loom.Push`.

  - `GET /api/push` gives the VAPID public key to subscribe with.
  - `POST /api/push/subscriptions` with `%{subscription:, origin:, test:}`
    keeps what `PushSubscription.toJSON()` returned, or an iPhone app's APNs
    token (`Loom.Push.subscribe/4`), and answers with the device's `endpoint`.
    The app sends it again on every start, so a subscription the browser
    rotated is picked up; `test` asks for a notification at once, when the
    user has just turned them on.
  - `DELETE /api/push/subscriptions` with `%{endpoint:}` forgets one.
  """
  use LoomWeb, :controller

  def show(conn, _params), do: json(conn, %{key: Loom.Push.public_key()})

  def create(conn, %{"subscription" => subscription, "origin" => origin} = params) do
    case Loom.Push.subscribe(subscription, origin, test: params["test"] == true) do
      {:ok, endpoint} -> json(conn, %{endpoint: endpoint})
      {:error, :invalid} -> conn |> put_status(422) |> json(%{error: "invalid subscription"})
    end
  end

  def create(conn, _params), do: conn |> put_status(422) |> json(%{error: "invalid subscription"})

  def delete(conn, %{"endpoint" => endpoint}) when is_binary(endpoint) do
    Loom.Push.unsubscribe(endpoint)
    send_resp(conn, 204, "")
  end

  def delete(conn, _params), do: conn |> put_status(422) |> json(%{error: "endpoint required"})
end
