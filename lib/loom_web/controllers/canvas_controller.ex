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

  ## Attachments

  What the user attached is served the same way under `/canvas-files/<id>/<token>/`,
  so a screenshot in a bubble opens in the canvas too. Same token, same
  sandbox: an uploaded HTML file is no more trusted than one the agent wrote.

  ## Range requests

  A single `Range: bytes=…` is answered with a 206 of just that slice. Safari
  will not play a video at all without it, and every browser needs it to seek.
  A multi-range request gets the whole file, which the spec allows.
  """
  use LoomWeb, :controller

  alias Loom.Agent
  alias Loom.Agent.Files
  alias Loom.Agent.Output
  alias Loom.Agent.Store

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
      token = Phoenix.Token.sign(LoomWeb.Endpoint, @salt, id)
      json(conn, %{base: "/canvas/#{id}/#{token}/", files: "/canvas-files/#{id}/#{token}/"})
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
      |> serve(path)
    else
      _ ->
        conn |> sandboxed() |> put_resp_content_type("text/plain") |> send_resp(404, "not found")
    end
  end

  # GET /canvas-files/:id/:token/:name — one attachment, checked the way a
  # submit checks it: a regular file inside this session's own `files/`.
  def attachment(conn, %{"id" => id, "token" => token, "name" => name}) do
    with {:ok, ^id} <- Phoenix.Token.verify(LoomWeb.Endpoint, @salt, token, max_age: @max_age),
         {:ok, [file]} <- Files.verify(id, [Path.join(Store.files_dir(id), name)]) do
      conn
      |> sandboxed()
      |> put_resp_content_type(type_of(file.path), nil)
      |> serve(file.path)
    else
      _ ->
        conn |> sandboxed() |> put_resp_content_type("text/plain") |> send_resp(404, "not found")
    end
  end

  defp serve(conn, path) do
    size = File.stat!(path).size
    conn = put_resp_header(conn, "accept-ranges", "bytes")

    case range(conn, size) do
      {first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, last - first + 1)

      :unsatisfiable ->
        conn |> put_resp_header("content-range", "bytes */#{size}") |> send_resp(416, "")

      nil ->
        send_file(conn, 200, path)
    end
  end

  # `{first, last}` inclusive, `:unsatisfiable` for a start past the end, or
  # `nil` to ignore the header and send everything.
  defp range(conn, size) do
    with ["bytes=" <> spec] <- get_req_header(conn, "range"),
         [one] <- String.split(spec, ","),
         true <- size > 0 do
      case String.split(String.trim(one), "-", parts: 2) do
        ["", suffix] ->
          with {n, ""} when n > 0 <- Integer.parse(suffix),
               do: {max(size - n, 0), size - 1},
               else: (_ -> nil)

        [first, last] ->
          with {f, ""} <- Integer.parse(first),
               {:ok, l} <- last_byte(last, size) do
            cond do
              f >= size -> :unsatisfiable
              f <= l -> {f, min(l, size - 1)}
              true -> nil
            end
          else
            _ -> nil
          end

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp last_byte("", size), do: {:ok, size - 1}

  defp last_byte(last, _size) do
    case Integer.parse(last) do
      {l, ""} -> {:ok, l}
      _ -> :error
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
