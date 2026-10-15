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
  transcript, plus whether the list was cut short.

  A deleted file is not reported: the card announces downloads, and there is
  nothing to download.
  """
  def changes(before, now) do
    changed =
      now
      |> Enum.reject(fn {rel, stamp} -> Map.get(before, rel) == stamp end)
      |> Enum.sort_by(fn {rel, _} -> rel end)

    files =
      changed
      |> Enum.take(@max_listed)
      |> Enum.map(fn {rel, {size, _mtime}} ->
        %{
          name: Path.basename(rel),
          path: rel,
          size: size,
          content_type: MIME.from_path(rel),
          updated: Map.has_key?(before, rel)
        }
      end)

    {files, length(changed) - length(files)}
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
