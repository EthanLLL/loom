defmodule LoomWeb.Plugs.NodeCliAuth do
  @moduledoc """
  Admits only the `loom-node` CLI on this host to `LoomWeb.NodeController`.

  These routes run commands on the user's machines, and they share a port with
  everything Cloudflare forwards in. Two checks, neither depending on how the
  tunnel or the zone is configured:

    - the `x-loom-key` header must match `Loom.Nodes.cli_key/0`, which is in a
      file only this user can read;
    - anything carrying `cf-ray` is refused outright, key or not: it came in
      through Cloudflare, and the CLI never does.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    key = conn |> get_req_header("x-loom-key") |> List.first()

    cond do
      get_req_header(conn, "cf-ray") != [] -> deny(conn)
      is_binary(key) and Plug.Crypto.secure_compare(key, Loom.Nodes.cli_key()) -> conn
      true -> deny(conn)
    end
  end

  defp deny(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, ~s({"error":"forbidden"}))
    |> halt()
  end
end
