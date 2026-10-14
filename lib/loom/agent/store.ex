defmodule Loom.Agent.Store do
  @moduledoc """
  On-disk persistence for agent sessions. Plain files, no database.

  The data is two append-only logs plus a small mutable header, written and read
  by one process per session. None of what a database gives you — indexes,
  cross-row queries, multi-writer concurrency — applies here, so the cost of
  SQLite (a NIF dependency, a schema to migrate) would buy nothing. JSONL also
  keeps the transcript greppable with `tail`/`jq`, which matters because it is
  the thing you read by hand when debugging an agent.

      ~/.loom/sessions/<id>/meta.json     header, rewritten in place
      ~/.loom/sessions/<id>/events.jsonl  normalized transcript events, append-only
      ~/.loom/sessions/<id>/files/…        what the user attached to the session

  Under the user's home rather than the release, because `priv/` is replaced
  wholesale by a deploy and none of this should be.

  ## Why there is no message log

  There used to be a second log holding the raw API messages, because loom ran
  the agent loop and needed something to resume from. The backends own the
  conversation now — Claude Code in `~/.claude/projects/…`, Codex in its thread
  store — so keeping a parallel copy here would be a second source of truth with
  nothing to reconcile it against.

  `events.jsonl` is therefore **display truth only**. It can legitimately differ
  from the backend's history: text streamed before an interrupt is in the
  transcript a user watched, but the backend discards it. Never try to correct
  one from the other.

  ## Durability

  Logs are opened with `:sync`, so each append reaches the disk before it
  returns. An agent turn takes seconds, so a few milliseconds of fsync per line
  is free — and it means the state on disk is never behind the state the model
  has already acted on.
  """

  require Logger

  @meta_file "meta.json"
  @events_file "events.jsonl"

  # ── Layout ────────────────────────────────────────────────────────────────

  @doc """
  Loom's own directory — `~/.loom`, or `LOOM_HOME` when it is set.

  Everything loom owns lives here: session headers, transcripts, and the files
  a user attached. Deliberately not under the release, where a deploy would
  replace it.
  """
  def home do
    Application.get_env(:loom, :home) || Path.expand("~/.loom")
  end

  @doc "Root directory for all session data."
  def data_dir do
    Application.get_env(:loom, Loom.Agent, [])[:data_dir] || Path.join(home(), "sessions")
  end

  @doc "Directory holding one session's header, logs, and session memory."
  def session_dir(id), do: Path.join(data_dir(), id)

  @doc """
  Directory holding the files a user attached to this session.

  Inside the session directory on purpose: deleting a session takes its
  attachments with it, and a path says on sight which conversation it belongs
  to. See `Loom.Agent.Files`.
  """
  def files_dir(id), do: Path.join(session_dir(id), "files")

  @doc """
  Bring sessions written before the data directory moved to `~/.loom` along.

  Copies, never moves, and skips any session that already exists in the new
  location — so it is idempotent and cannot overwrite live state. Leaving the
  old copy behind costs a few megabytes and is the difference between a mistake
  here being annoying and being unrecoverable.

  Per session rather than "only if the target directory is absent": an upload
  or a new session creates that directory, and a boot after one of those must
  still find the old conversations.
  """
  def migrate_legacy do
    legacy = legacy_dir()

    copied =
      case File.ls(legacy) do
        {:ok, ids} -> Enum.count(ids, &copy_legacy(legacy, &1))
        {:error, _} -> 0
      end

    if copied > 0 do
      Logger.info("Loom.Agent.Store copied #{copied} session(s) from #{legacy} to #{data_dir()}")
    end

    :ok
  rescue
    error ->
      # A failed migration must not stop the node from booting: the old
      # directory is untouched, so the worst case is sessions not showing up
      # until someone looks at this line.
      Logger.error("Loom.Agent.Store could not migrate legacy sessions: #{inspect(error)}")
      :error
  end

  # Where sessions lived before `~/.loom`. Overridable so the migration can be
  # tested against a directory of its own rather than the release's real one.
  defp legacy_dir do
    Application.get_env(:loom, Loom.Agent, [])[:legacy_dir] ||
      Path.join(to_string(:code.priv_dir(:loom)), "agent_sessions")
  end

  defp copy_legacy(legacy, id) do
    from = Path.join(legacy, id)
    to = session_dir(id)

    # A directory with no header is not a session — the old location collected
    # a few stray temp directories from tests.
    if File.regular?(Path.join(from, @meta_file)) do
      # Entry by entry, never overwriting. A session that is already half in the
      # new location — a header rewritten there while its transcript stayed
      # behind — still gets the rest of itself back.
      missing = Enum.reject(File.ls!(from), &File.exists?(Path.join(to, &1)))

      if missing == [] do
        false
      else
        File.mkdir_p!(to)
        for entry <- missing, do: File.cp_r!(Path.join(from, entry), Path.join(to, entry))
        true
      end
    else
      false
    end
  end

  # ── Meta ──────────────────────────────────────────────────────────────────

  @doc """
  Write (or rewrite) a session's header.

  Written to a temp file and renamed, so a crash mid-write leaves the previous
  header intact rather than a truncated one. The append-only logs need no such
  care — a torn final line is simply dropped on read.
  """
  def write_meta(id, meta) do
    dir = session_dir(id)
    File.mkdir_p!(dir)
    path = Path.join(dir, @meta_file)
    tmp = path <> ".tmp"

    File.write!(tmp, Jason.encode_to_iodata!(meta))
    File.rename!(tmp, path)
    :ok
  end

  @doc """
  Read one session's header, or `:error` if it is missing, unreadable, or not
  a header we recognise.

  Never raises: `list_metas/0` walks whatever happens to be in the data
  directory, and one bad entry must not stop the rest of the sessions from
  coming back.
  """
  def read_meta(id) do
    with {:ok, body} <- File.read(Path.join(session_dir(id), @meta_file)),
         {:ok, raw} <- Jason.decode(body),
         %{"id" => _} <- raw do
      {:ok, Map.new(raw, fn {key, value} -> {atomize(key), value} end)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Every session header on disk, oldest first.

  Deliberately cheap: reading only the headers is what lets startup bring every
  session's process up without touching the logs.
  """
  def list_metas do
    case File.ls(data_dir()) do
      {:ok, ids} ->
        ids
        |> Enum.sort()
        |> Enum.map(&read_meta/1)
        |> Enum.flat_map(fn
          {:ok, meta} -> [meta]
          :error -> []
        end)
        |> Enum.sort_by(& &1[:created_at])

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("Loom.Agent.Store cannot list #{data_dir()}: #{inspect(reason)}")
        []
    end
  end

  @doc "Remove a session's directory and everything in it."
  def delete_session(id) do
    File.rm_rf!(session_dir(id))
    :ok
  end

  # ── Append-only logs ──────────────────────────────────────────────────────

  @doc """
  Open a session's logs for appending.

  Returns a handle to pass to `append_event/2`. The owning session holds it for
  its lifetime and closes it in `terminate/2`; re-opening per write would cost
  two syscalls per line for no benefit.
  """
  def open_logs(id) do
    dir = session_dir(id)
    File.mkdir_p!(dir)

    with {:ok, events} <- open_append(Path.join(dir, @events_file)) do
      {:ok, %{events: events}}
    end
  end

  defp open_append(path), do: :file.open(path, [:append, :binary, :sync, :raw])

  @doc "Close a log handle. Safe to call with `nil`."
  def close_logs(nil), do: :ok

  def close_logs(%{events: events}) do
    :file.close(events)
    :ok
  end

  @doc "Append one transcript event."
  def append_event(%{events: io}, event), do: append_line(io, event)
  def append_event(nil, _event), do: :ok

  defp append_line(io, term) do
    case :file.write(io, [Jason.encode_to_iodata!(term), "\n"]) do
      :ok ->
        :ok

      {:error, reason} ->
        # Losing a line is survivable (see moduledoc) and must not take the
        # conversation down with it, so this is logged rather than raised.
        Logger.error("Loom.Agent.Store append failed: #{inspect(reason)}")
        :ok
    end
  end

  # ── Reading logs back ─────────────────────────────────────────────────────

  @doc """
  Read a session's transcript events, newest first, at most `limit` of them.

  Decoded back into the exact shape `emit/3` produces, so a restored event is
  indistinguishable from a fresh one — atom keys, and `kind`/`status` as atoms
  rather than the strings JSON gives back.

  The conversion is explicit rather than `Jason`'s `keys: :atoms!` because that
  would also rewrite nested data: a tool's `input` carries arbitrary
  model-supplied keys, which must stay strings and would otherwise raise the
  moment the model used a name no atom exists for.
  """
  def read_events(id, limit) do
    Path.join(session_dir(id), @events_file)
    |> read_jsonl([])
    |> Enum.reverse()
    |> Enum.take(limit)
    |> Enum.flat_map(fn raw ->
      case decode_event(raw) do
        {:ok, event} -> [event]
        :error -> []
      end
    end)
  end

  defp decode_event(%{"seq" => seq, "at" => at, "kind" => kind, "payload" => payload})
       when is_integer(seq) and is_binary(kind) and is_map(payload) do
    {:ok, %{seq: seq, at: at, kind: atomize(kind), payload: decode_payload(payload)}}
  end

  defp decode_event(_), do: :error

  # Only the top-level payload keys become atoms. `input` and `details` hold
  # opaque nested data (tool arguments, error bodies) and are left untouched.
  defp decode_payload(payload) do
    Map.new(payload, fn {key, value} -> {atomize(key), decode_value(key, value)} end)
  end

  defp decode_value("status", value) when is_binary(value), do: atomize(value)
  defp decode_value(_key, value), do: value

  # Falls back to the string when no such atom exists, so one unfamiliar field
  # degrades that field instead of discarding an otherwise good event — and a
  # corrupt file can never grow the atom table.
  defp atomize(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> string
  end

  defp read_jsonl(path, opts) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line, opts) do
            {:ok, term} ->
              [term]

            {:error, _} ->
              # A torn trailing line from a crash mid-append. Dropping it is the
              # whole reason an append-only log needs no recovery procedure.
              []
          end
        end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("Loom.Agent.Store cannot read #{path}: #{inspect(reason)}")
        []
    end
  end
end
