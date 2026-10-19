defmodule Loom.Agent.Files do
  @moduledoc """
  The files a user attaches to a session: where they land, and how the model is
  told about them.

  Uploads are written to `<session_dir>/files/<name>` (see
  `Loom.Agent.Store.files_dir/1`) and nothing is read, decoded or converted
  here. The absolute path goes to the model in the message text and the backend
  reads it with its own tools — Claude Code's `Read` renders an image, Codex has
  `view_image` — which costs one tool round-trip and in exchange:

    - works for every file type, not just the ones we taught it about;
    - never base64s a 20 MB screenshot through stdio or JSON-RPC;
    - needs no second content format in either adapter, so `run_turn/2` still
      takes a string.

  ## Display text and model text are not the same string

  The transcript event keeps what the user actually typed plus the attachment
  list as structured data, so a bubble can show `shot.png` as a chip. Only the
  message handed to the backend carries the paths — see `prompt/2`. Putting the
  paths in the displayed text instead would mean every attachment permanently
  turns the user's own sentence into 70 characters of absolute path.

  ## A path is a capability

  The client echoes back the path that `store/2` returned, and the model will
  read whatever we name — so `verify/2` refuses anything that is not inside this
  session's own files directory. The agent runs unsandboxed and could read that
  file on its own initiative anyway; the point is that a client cannot make it
  happen silently by rewriting one field.
  """

  alias Loom.Agent.Store

  # Generous for a screenshot or a log, small enough that a mis-drop of a video
  # fails fast instead of filling the disk.
  @max_bytes 25 * 1024 * 1024
  @max_name_length 100

  @doc """
  Store one upload under `session_id` and describe where it went.

  Returns `{:error, :too_large}` or `{:error, :empty}` rather than raising: a
  bad file in a multi-file drop should report itself, not take the request down.
  """
  def store(session_id, %{filename: filename, path: tmp}) do
    with {:ok, size} <- measure(tmp) do
      dir = Store.files_dir(session_id)
      File.mkdir_p!(dir)

      name = unique(dir, safe_name(filename))
      dest = Path.join(dir, name)

      # Copy, not rename: the upload sits in the system temp directory, which
      # may be a different filesystem.
      File.cp!(tmp, dest)

      {:ok, %{name: name, path: dest, size: size, content_type: MIME.from_path(name)}}
    end
  end

  @doc """
  Check that each path really is one of this session's attachments, and
  describe it.

  Refuses on the first path that is not, because a submit carrying one bogus
  path is a client bug or an attempt — either way the user should hear about it
  rather than have it quietly dropped.
  """
  def verify(_session_id, []), do: {:ok, []}

  def verify(session_id, paths) when is_list(paths) do
    dir = session_id |> Store.files_dir() |> Path.expand()

    paths
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      path = raw |> to_string() |> Path.expand()

      if String.starts_with?(path, dir <> "/") and File.regular?(path) do
        {:cont, {:ok, [describe(path) | acc]}}
      else
        {:halt, {:error, {:not_an_attachment, to_string(raw)}}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The message the backend receives: what the user typed, then the paths.

  The model is told these are local files it may read, because otherwise a bare
  path in a sentence is ambiguous — it could be a file the user wants *written*.
  """
  def prompt(text, []), do: text

  def prompt(text, files) do
    paths = Enum.map_join(files, "\n", &"- #{&1.path}")

    header =
      "Attached #{length(files)} file#{if length(files) == 1, do: "", else: "s"} " <>
        "on this machine — read #{if length(files) == 1, do: "it", else: "them"} from these paths:"

    [String.trim(text), header, paths]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Every attachment the session has, for the file browser: stored name, size
  and mtime (posix seconds), by name.

  The directory is flat — `store/2` never makes subdirectories — so this is one
  `ls`. Hidden files and anything that is not a regular file are skipped, the
  same files `verify/2` would refuse to hand back.
  """
  def list(session_id) do
    dir = Store.files_dir(session_id)

    case File.ls(dir) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            not String.starts_with?(name, "."),
            {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} <-
              [File.lstat(Path.join(dir, name), time: :posix)],
            do: %{path: name, size: size, mtime: mtime}

      {:error, _} ->
        []
    end
  end

  @doc """
  A name for a session whose first message was an attachment with no words.

  Without it such a session shows up in the sidebar as an opaque id.
  """
  def title(files) do
    files |> Enum.map_join(", ", & &1.name) |> String.slice(0, 80)
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp describe(path) do
    size =
      case File.stat(path) do
        {:ok, %{size: size}} -> size
        _ -> 0
      end

    %{name: Path.basename(path), path: path, size: size, content_type: MIME.from_path(path)}
  end

  defp measure(tmp) do
    case File.stat(tmp) do
      {:ok, %{size: 0}} -> {:error, :empty}
      {:ok, %{size: size}} when size > @max_bytes -> {:error, :too_large}
      {:ok, %{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  # The filename comes from the client, so it is a hostile string: `../../`, a
  # NUL, a Windows path, or four kilobytes of nothing. Letters are kept as they
  # are — including CJK, which the author's filenames are full of — and anything
  # that could mean "a directory" or confuse a shell is replaced.
  defp safe_name(filename) do
    filename
    |> to_string()
    |> Path.basename()
    |> String.replace(~r/[\x00-\x1f\/\\:*?"<>|]/u, "_")
    |> String.trim()
    |> clamp()
    |> case do
      "" -> "file"
      "." -> "file"
      ".." -> "file"
      name -> name
    end
  end

  # Truncate the stem, not the extension: the extension is what tells the
  # backend (and the model) what it is looking at.
  defp clamp(name) do
    if String.length(name) <= @max_name_length do
      name
    else
      ext = Path.extname(name)
      stem = String.slice(Path.basename(name, ext), 0, @max_name_length - String.length(ext))
      stem <> ext
    end
  end

  defp unique(dir, name) do
    if File.exists?(Path.join(dir, name)), do: unique(dir, name, 1), else: name
  end

  defp unique(dir, name, n) do
    ext = Path.extname(name)
    candidate = "#{Path.basename(name, ext)}-#{n}#{ext}"
    if File.exists?(Path.join(dir, candidate)), do: unique(dir, name, n + 1), else: candidate
  end
end
