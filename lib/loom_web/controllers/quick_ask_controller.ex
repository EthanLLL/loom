defmodule LoomWeb.QuickAskController do
  @moduledoc """
  Quick Ask over HTTP; see `Loom.QuickAsk`.

  - `GET /api/quick-ask/settings` gives `%{backend:, model:}`.
  - `PUT /api/quick-ask/settings` with `%{backend:, model:}` changes it; a
    missing or empty `model` is the backend's default.
  - `POST /api/quick-ask` with `%{text:, device:}` starts the session and
    answers with its `id`.
  """
  use LoomWeb, :controller

  def show(conn, _params), do: json(conn, Loom.QuickAsk.settings())

  def update(conn, %{"backend" => backend} = params) do
    model = if params["model"] in [nil, ""], do: nil, else: params["model"]

    case Loom.QuickAsk.put_settings(backend, model) do
      {:ok, settings} -> json(conn, settings)
      {:error, reason} -> conn |> put_status(422) |> json(%{error: reason})
    end
  end

  def update(conn, _params),
    do: conn |> put_status(422) |> json(%{error: "`backend` is required"})

  def create(conn, %{"text" => text} = params) when is_binary(text) do
    case Loom.QuickAsk.ask(text, origin: Map.get(params, "device", "unknown")) do
      {:ok, id} -> conn |> put_status(:created) |> json(%{id: id})
      {:error, reason} when is_binary(reason) -> conn |> put_status(422) |> json(%{error: reason})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def create(conn, _params), do: conn |> put_status(422) |> json(%{error: "`text` is required"})
end
