defmodule Loom.Agent.Output do
  @moduledoc """
  The files an agent produces for the user: where it is told to put them, how
  the session notices them, and which of them a download may name.

  The mirror image of `Loom.Agent.Files`. Attachments go in
  `<session_dir>/files/`, deliverables come out of `<session_dir>/output/`, and
  deleting a session takes both with it.

  ## The agent is told, not watched

  Both backends write wherever they like, so the only way to know which file is
  meant for the user is to agree on a place in advance. `instructions/1` is that
  agreement, handed to the backend as part of its system prompt. An absolute
  path rather than an environment variable, because Codex runs every session's
  thread in one shared app-server — there is no per-session process to give an
  environment to.

  ## Noticed at the end of a turn, not as it happens

  The session snapshots the directory when it starts and compares again when a
  turn ends — done, failed or interrupted — and announces whatever is new or
  changed as one event. Not after every tool call: a tool result only says that
  one command ended, a script that rewrites `report.xlsx` three times would
  announce it three times, and the end of the turn is the point at which the
  model itself considers the file finished.

  This is also why nothing depends on what the model writes in its reply. A
  reply that forgets to mention the file, or links it wrongly, still leaves the
  file on the card.
  """

  alias Loom.Agent.Store

  # One turn producing more than this is a build directory dumped in by mistake,
  # not a set of deliverables. The card names the first ones and says so.
  @max_listed 50

  @doc "Make sure the directory exists, so the agent can write straight into it."
  def ensure_dir(session_id) do
    File.mkdir_p!(Store.output_dir(session_id))
    :ok
  end

  @doc """
  What the backend is told on top of its own system prompt.

  Names the absolute path, says it is the one place the user can download from,
  and asks for links in the `output/<name>` form the UI turns into downloads.
  """
  def instructions(session_id) do
    dir = Store.output_dir(session_id)

    """
    You are running inside Loom, a web UI. The user reads your replies in a \
    browser and cannot see this machine's filesystem.

    When you produce a file meant for the user — a spreadsheet, a slide deck, a \
    document, an image, an archive, anything they should download — save it in \
    #{dir} (subdirectories are fine). Files written there are offered to the \
    user for download automatically when your turn ends; files written anywhere \
    else are not. Use descriptive file names. When you mention such a file in \
    your reply, link it as [name](output/<path relative to that directory>).

    Next to the chat is a canvas: a browser pane. When something is better \
    seen than downloaded — a chart or dashboard, a gallery of images, a video, \
    a small web page — build it as a self-contained page: \
    #{dir}/<name>/index.html with its assets beside it, referenced by relative \
    paths. The newest such index.html opens in the canvas by itself when your \
    turn ends; each subdirectory is shown as a single card (one with an \
    index.html opens as a page, any other is offered as a zip). The page runs \
    sandboxed with no access to Loom itself; it may load libraries from public \
    CDNs. Don't build a page when a plain file is what the user asked for.
    """
  end

  @doc """
  The directory as it stands: relative path ↦ `{size, mtime}`.

  Regular files only, hidden ones skipped — Office's `~$report.xlsx` lock files
  and editor swap files are not deliverables. `lstat`, so a symlink is skipped
  too: `resolve/2` would refuse to serve it.
  """
  def snapshot(session_id) do
    dir = Store.output_dir(session_id)

    Path.join(dir, "**")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      rel = Path.relative_to(path, dir)

      with false <- hidden?(rel),
           {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <-
             File.lstat(path, time: :posix) do
        [{rel, {size, mtime}}]
      else
        _ -> []
      end
    end)
    |> Map.new()
  end

  @doc """
  What is new or different in `now` compared with `before`, described for the
  transcript as `%{files: entries, more: n, open: path | nil}`.

  One entry per top-level name in the directory, not per file: a file directly
  in `output/` is itself, and a directory is one entry however many files it
  holds — a comic chapter of forty pages is one card, not forty. A directory
  counts as changed when anything in it did. One with an `index.html` is a page,
  and opens in the canvas; one without is offered as a zip.

  `open` is the page the canvas should show without being asked: the most
  recently written `index.html` among the changes, at the top level or one
  directory down. Only pages open on their own; everything else waits for a
  click.

  A deleted file is not reported: the card announces downloads, and there is
  nothing to download.
  """
  def changes(before, now) do
    changed = Enum.reject(now, fn {rel, stamp} -> Map.get(before, rel) == stamp end)

    entries =
      changed
      |> Enum.group_by(fn {rel, _} -> top(rel) end)
      |> Enum.sort_by(fn {top, _} -> top end)
      |> Enum.map(fn {top, _} -> entry(top, before, now) end)

    listed = Enum.take(entries, @max_listed)

    %{files: listed, more: length(entries) - length(listed), open: page_to_open(changed, now)}
  end

  defp top(rel), do: rel |> Path.split() |> hd()

  defp entry(top, before, now) do
    case Map.fetch(now, top) do
      {:ok, {size, _mtime}} ->
        %{
          kind: "file",
          name: top,
          path: top,
          size: size,
          content_type: MIME.from_path(top),
          updated: Map.has_key?(before, top)
        }

      :error ->
        inside = for {rel, stamp} <- now, under?(rel, top), do: {rel, stamp}
        index = Path.join(top, "index.html")

        %{
          kind: "dir",
          name: top,
          path: top,
          size: inside |> Enum.map(fn {_, {size, _}} -> size end) |> Enum.sum(),
          files: length(inside),
          index: if(Map.has_key?(now, index), do: index),
          content_type: "inode/directory",
          updated: Enum.any?(Map.keys(before), &under?(&1, top))
        }
    end
  end

  defp under?(rel, top), do: String.starts_with?(rel, top <> "/")

  # The newest `index.html` among the pages that changed. A page's images being
  # rewritten while its index stayed the same still changes what it shows.
  defp page_to_open(changed, now) do
    changed
    |> Enum.map(fn {rel, _} -> page_of(rel) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(now, &1))
    |> Enum.max_by(fn index -> elem(Map.fetch!(now, index), 1) end, fn -> nil end)
  end

  defp page_of("index.html"), do: "index.html"

  defp page_of(rel) do
    case Path.split(rel) do
      [_only] -> nil
      [top | _] -> Path.join(top, "index.html")
    end
  end

  @doc """
  The absolute path of one of this session's output *directories*, for a zip.
  Same rules as `resolve/2`, for a directory instead of a file.
  """
  def resolve_dir(session_id, rel) do
    dir = session_id |> Store.output_dir() |> Path.expand()
    path = Path.expand(to_string(rel), dir)

    cond do
      not String.starts_with?(path, dir <> "/") -> :error
      hidden?(Path.relative_to(path, dir)) -> :error
      not File.dir?(path) -> :error
      not inside?(path, dir) -> :error
      true -> {:ok, path}
    end
  end

  @doc """
  The absolute path a download names, if it really is one of this session's
  outputs.

  `rel` comes from a URL, so it is hostile: `..`, an absolute path, a symlink
  out. Expanded and checked against the directory rather than pattern-matched,
  the same rule `Loom.Agent.Files.verify/2` applies to attachments.
  """
  def resolve(session_id, rel) do
    dir = session_id |> Store.output_dir() |> Path.expand()
    path = Path.expand(to_string(rel), dir)

    cond do
      not String.starts_with?(path, dir <> "/") -> :error
      hidden?(Path.relative_to(path, dir)) -> :error
      not File.regular?(path) -> :error
      # A symlink the agent left pointing elsewhere would otherwise serve
      # whatever it points at.
      not inside?(path, dir) -> :error
      true -> {:ok, path}
    end
  end

  @doc """
  Every file a zip of `rel` may contain, relative to the output directory: the
  same files `resolve/2` would serve one at a time, and nothing else.
  """
  def files_under(session_id, rel) do
    prefix = String.trim_trailing(rel, "/") <> "/"

    session_id
    |> snapshot()
    |> Enum.filter(fn {path, _} ->
      String.starts_with?(path, prefix) and match?({:ok, _}, resolve(session_id, path))
    end)
    |> Enum.map(fn {path, {size, _}} -> {path, size} end)
    |> Enum.sort()
  end

  defp hidden?(rel) do
    rel
    |> Path.split()
    |> Enum.any?(&(String.starts_with?(&1, ".") or String.starts_with?(&1, "~$")))
  end

  # No component between the directory and the file may be a symlink. Stricter
  # than resolving the link and checking where it lands, and nothing an agent
  # writes as a deliverable needs one.
  defp inside?(path, dir) do
    path
    |> Path.relative_to(dir)
    |> Path.split()
    |> Enum.scan(dir, &Path.join(&2, &1))
    |> Enum.all?(&match?({:ok, %File.Stat{type: type}} when type != :symlink, File.lstat(&1)))
  end
end
