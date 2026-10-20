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
  alias Loom.Agent.Files
  alias Loom.Agent.Output
  alias Loom.Agent.Store

  # Built in a temp file, so memory stays flat; past this it is refused rather
  # than leaving the user waiting on a zip the size of a disk.
  @zip_limit 1024 * 1024 * 1024

  # GET /api/agents/:id/tree — everything the session holds: what the user
  # attached (`files/`) and what the agent made (`output/`), for the canvas's
  # file browser. Listed, not read; each file is then fetched by its own route.
  def tree(conn, %{"id" => id}) do
    if Agent.exists?(id) do
      json(conn, %{files: Files.list(id), output: Output.list(id)})
    else
      conn |> put_status(:not_found) |> json(%{error: "unknown session"})
    end
  end

  # GET /api/agents/:id/zip/*path — one output directory as a zip, stored
  # rather than compressed: what agents produce in bulk (images, video) is
  # compressed already.
  def zip(conn, %{"id" => id, "path" => parts}) do
    with true <- Agent.exists?(id),
         rel = Path.join(parts),
         {:ok, dir} <- Output.resolve_dir(id, rel),
         [_ | _] = files <- Output.files_under(id, rel) do
      total = files |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      if total > @zip_limit do
        conn
        |> put_status(:request_entity_too_large)
        |> json(%{error: "over 1 GB; too big to zip"})
      else
        send_zip(conn, id, dir, files)
      end
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "no such output directory"})
    end
  end

  defp send_zip(conn, id, dir, files) do
    name = Path.basename(dir)
    base = Path.dirname(dir)
    root = id |> Store.output_dir() |> Path.expand()
    tmp = Path.join(System.tmp_dir!(), "loom-#{System.unique_integer([:positive])}.zip")

    # Named from the directory's parent, so the zip unpacks into one folder.
    entries =
      for {rel, _} <- files,
          do: root |> Path.join(rel) |> Path.relative_to(base) |> String.to_charlist()

    try do
      {:ok, _} =
        :zip.create(String.to_charlist(tmp), entries,
          cwd: String.to_charlist(base),
          uncompress: :all
        )

      send_download(conn, {:file, tmp}, filename: name <> ".zip")
    after
      File.rm(tmp)
    end
  end

  # DELETE /api/agents/:id/output/*path — a file, or a directory and all in it.
  def delete(conn, %{"id" => id, "path" => parts}) do
    with true <- Agent.exists?(id), :ok <- Output.delete(id, Path.join(parts)) do
      send_resp(conn, :no_content, "")
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "no such output"})
    end
  end

  # PATCH /api/agents/:id/output/*path {new_name} — renamed where it is.
  def update(conn, %{"id" => id, "path" => parts, "new_name" => name}) do
    with true <- Agent.exists?(id),
         {:ok, path} <- Output.rename(id, Path.join(parts), name) do
      json(conn, %{path: path})
    else
      {:error, reason} -> rename_failed(conn, reason)
      _ -> conn |> put_status(:not_found) |> json(%{error: "no such output"})
    end
  end

  @doc false
  def rename_failed(conn, :exists),
    do: conn |> put_status(:conflict) |> json(%{error: "that name is taken"})

  def rename_failed(conn, :bad_name),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "not a usable name"})

  def rename_failed(conn, :not_found),
    do: conn |> put_status(:not_found) |> json(%{error: "no such file"})

  def rename_failed(conn, reason),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})

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
