defmodule LoomWeb.SessionController do
  use LoomWeb, :controller

  alias Loom.Terminal

  # GET /api/sessions — list live sessions (the authoritative list).
  def index(conn, _params) do
    json(conn, %{sessions: Enum.map(Terminal.list_sessions(), &view/1)})
  end

  # POST /api/sessions — create a new session with a server-generated id.
  def create(conn, params) do
    id = generate_id()
    opts = build_opts(params)

    case Terminal.start_session(id, opts) do
      {:ok, _pid} ->
        conn
        |> put_status(:created)
        |> json(view(Terminal.info(id)))

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  # DELETE /api/sessions/:id — stop a session and its shell.
  def delete(conn, %{"id" => id}) do
    case Terminal.stop_session(id) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> send_resp(conn, :not_found, "")
    end
  end

  defp build_opts(params) do
    []
    |> maybe_put(:title, params["title"])
    |> maybe_put(:cols, parse_int(params["cols"]))
    |> maybe_put(:rows, parse_int(params["rows"]))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: [{key, val} | opts]

  defp parse_int(n) when is_integer(n), do: n
  defp parse_int(n) when is_binary(n), do: with({v, _} <- Integer.parse(n), do: v)
  defp parse_int(_), do: nil

  defp generate_id do
    "s_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
  end

  defp view(info) do
    %{
      id: info.id,
      title: info.title,
      created_at: info.created_at,
      cols: info.cols,
      rows: info.rows
    }
  end
end
