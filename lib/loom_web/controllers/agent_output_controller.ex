defmodule LoomWeb.AgentOutputController do
  @moduledoc """
  Downloads of what an agent produced for the user.

  Behind the same bearer-token check as every other API route, which is why the
  client fetches these rather than linking to them: a plain `<a href>` cannot
  carry the header. Serving the directory statically would have meant anyone
  holding a URL could read the file.

  The path comes from the URL and is checked by `Loom.Agent.Output.resolve/2`
  before anything is read. See that module for what counts as an output.
  """
  use LoomWeb, :controller

  alias Loom.Agent
  alias Loom.Agent.Output

  # GET /api/agents/:id/output/*path
  def show(conn, %{"id" => id, "path" => parts}) do
    # Also what keeps the id from being a path: an unknown one has no process.
    with true <- Agent.exists?(id),
         {:ok, path} <- Output.resolve(id, Path.join(["." | parts])) do
      send_download(conn, {:file, path}, filename: Path.basename(path))
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "no such output"})
    end
  end
end
