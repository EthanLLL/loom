defmodule LoomWeb.CanvasController do
  @moduledoc """
  The canvas: a session's `output/` directory, served to an `<iframe>` so a page
  the agent built — a dashboard, a gallery, a video player — runs next to the
  chat.

  ## What the agent wrote is hostile

  A page is model output, and the model reads web pages. Run on loom's own
  origin, its script could read the login token from `localStorage` and drive
  every agent on the machine. So every response here carries a
  `Content-Security-Policy: sandbox` without `allow-same-origin`: the page gets
  an opaque origin, whether it is shown in loom's sandboxed iframe or opened in
  a tab of its own. It can run scripts, load libraries from CDNs and read the
  files beside it, and nothing of loom's.

  ## Why the token is in the path

  An iframe cannot send the bearer header, so `token/2` hands the client a
  signed, session-scoped prefix — `/canvas/<id>/<token>/` — valid for a day. In
  the path rather than the query string, so the page's own relative URLs
  (`img/01.jpg`, `data.json`) inherit it. `Referrer-Policy: no-referrer` keeps it
  from being sent along to the CDNs a page loads from.

  Range requests are not served yet, so a long video plays but cannot seek.
  """
  use LoomWeb, :controller

  alias Loom.Agent
  alias Loom.Agent.Output

  @salt "canvas"
  @max_age 24 * 60 * 60

  # Whatever the browser should display as text rather than offer as a
  # download: logs, data, and source code. `.js` and `.css` keep their own
  # types, because pages load them.
  @as_text ~w(.md .markdown .txt .log .csv .tsv .jsonl .ndjson .yaml .yml .toml .ini .conf
              .py .rb .go .rs .java .kt .c .h .cc .cpp .hpp .cs .swift .ex .exs
              .erl .sh .bash .zsh .fish .ts .tsx .jsx .sql .lua .r .diff .patch)

  # POST /api/agents/:id/canvas — the prefix this session's canvas is served under.
  def token(conn, %{"id" => id}) do
    if Agent.exists?(id) do
      json(conn, %{base: "/canvas/#{id}/#{Phoenix.Token.sign(LoomWeb.Endpoint, @salt, id)}/"})
    else
      conn |> put_status(:not_found) |> json(%{error: "unknown session"})
    end
  end

  # GET /canvas/:id/:token/*path
  def show(conn, %{"id" => id, "token" => token} = params) do
    rel = Path.join(Map.get(params, "path", []))

    with {:ok, ^id} <- Phoenix.Token.verify(LoomWeb.Endpoint, @salt, token, max_age: @max_age),
         {:ok, path} <- locate(id, rel) do
      conn
      |> sandboxed()
      |> put_resp_content_type(type_of(path), nil)
      |> send_file(200, path)
    else
      _ ->
        conn |> sandboxed() |> put_resp_content_type("text/plain") |> send_resp(404, "not found")
    end
  end

  # A directory means its index.html.
  defp locate(id, rel) do
    case Output.resolve(id, rel) do
      {:ok, path} -> {:ok, path}
      :error -> Output.resolve(id, Path.join(rel, "index.html"))
    end
  end

  defp sandboxed(conn) do
    conn
    |> put_resp_header(
      "content-security-policy",
      "sandbox allow-scripts allow-forms allow-popups allow-modals allow-downloads"
    )
    # Module scripts and fetch() from an opaque origin are CORS requests.
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    # Pages are rewritten in place turn after turn.
    |> put_resp_header("cache-control", "no-cache")
  end

  defp type_of(path) do
    ext = path |> Path.extname() |> String.downcase()

    cond do
      ext in @as_text -> "text/plain; charset=utf-8"
      ext in ~w(.html .htm) -> "text/html; charset=utf-8"
      ext == ".json" -> "application/json; charset=utf-8"
      true -> MIME.from_path(path)
    end
  end
end
