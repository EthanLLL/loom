defmodule Loom.Agent.Backend do
  @moduledoc """
  The agent engine behind one session: Claude Code or Codex.

  Loom does not run an agent loop of its own. A session binds to one backend
  conversation for life and this module is the only thing that knows how to talk
  to it. Everything above it — the queue, event numbering, the transcript, the
  channel — is backend-agnostic.

  See `docs/backends.md` for the measured protocol details and why
  each of these callbacks has the shape it does.

  ## run_turn starts a turn; steer joins one

  `run_turn/2` means *start a turn now* and is only called when none is running.
  `steer/2` injects a message into the turn that **is** running — and both
  backends do that natively, which is worth spelling out because it was measured
  rather than assumed:

    * Claude Code takes it on stdin and injects it at the next tool-result
      boundary. Measured: a message sent 16 s into a five-step shell task was
      delivered alongside step two's output and the model abandoned steps three
      to five. **One** `result`, not two. With no tool boundary left (a pure
      text answer) it falls through to the next turn instead.
    * Codex has `turn/steer` with an `expectedTurnId`, and injects immediately —
      measured at 0.0 s rather than at a boundary. The turn id makes it
      race-safe: if the turn has already ended the call fails instead of
      being misdelivered.

  So a message typed while the agent is working reaches it *during* that turn.
  Holding it in a queue until the turn ended would throw that away — the whole
  point of typing "no, not like that" is that it lands before the work is done.

  The session still keeps a queue, but only for `:interrupted`: there is no
  running turn to join, so those messages wait for the user to continue.

  ## Two very different process models, one contract

  The implementations are not symmetric, and pretending otherwise is what makes
  the abstraction leak:

    * **Claude Code** is one `claude -p` process per session, spawned on the
      first turn and kept between turns, then killed by `release/1` once the
      session idles. The conversation survives in
      `~/.claude/projects/<cwd-slug>/<uuid>.jsonl`, so the next turn after a
      release respawns with `--resume <uuid>` and pays only the cold start.

    * **Codex** runs as a single long-lived `codex app-server` shared by every
      codex session on the node, addressed by `threadId`. Starting a turn is a
      JSON-RPC call into that shared process, not a spawn.

  So `handle` is opaque, and `decode/2` — not a port message pattern in the
  session — is what turns backend output into events. A session forwards any
  message it does not recognise; the backend claims what is its own and returns
  `:ignore` for the rest.

  ## Why decode/2 returns a handle

  Both backends learn identity from their own output: Claude Code reports its
  `session_id` in `system/init`, Codex reports `turn.id` in `turn/started` and we
  need it to interrupt. Decoding is therefore a state transition, not a pure
  function, and the session persists what comes back.

  ## Events carry no seq

  `decode/2` returns `{kind, payload}` pairs. Sequence numbers and timestamps are
  assigned by the session, which is the sole writer of `events.jsonl`. Backend
  identifiers (Claude Code's message uuid, Codex's `turnId`/`itemId`) travel
  inside the payload as `backend_ref` so a client that reattaches can de-duplicate
  without comparing content.
  """

  @typedoc "Which engine a session is bound to. Chosen at creation, never changed."
  @type kind :: :claude_code | :codex

  @typedoc """
  Backend-private state. Holds whatever identifies the live conversation and any
  in-flight decoding state (partial lines, the current turn id).
  """
  @type handle :: term()

  @typedoc """
  One transcript event, minus the bookkeeping the session owns.

  The session wraps it into `%{seq:, at:, kind:, payload:}` before appending and
  broadcasting.
  """
  @type event :: {kind :: atom(), payload :: map()}

  @typedoc """
  What `decode/2` produces, in the order it must be delivered.

  Two kinds, because the existing client protocol has two layers and they are
  not interchangeable:

    * `{:event, kind, payload}` — numbered, persisted to `events.jsonl`,
      replayable to a client that reattaches. The source of truth.
    * `{:delta, map}` — transient typewriter output carrying a `block_id`,
      broadcast and then forgotten. A client that missed it gets the
      authoritative event instead.

  Delta `type`s a client has to handle: `:block_start`, `:block_end`, `:text`,
  `:thinking`, `:tool_use_start`, and `:tool_output` — a chunk of a running
  tool's output, keyed by the tool card's `block_id`. `:tool_output` exists so a
  ten-minute build does not look hung; the `:tool_result` event that follows
  replaces whatever accumulated.

  Order within the list is preserved: a block's `:block_start` delta has to reach
  clients before the deltas that fill it.
  """
  @type out :: {:event, kind :: atom(), payload :: map()} | {:delta, map()}

  @doc """
  Begin a brand-new backend conversation.

  Must not return until the backend's own identifier is known or can be derived,
  because the session persists it immediately — a crash between "started" and
  "recorded" would orphan a conversation we can never find again.
  """
  @callback start(session_id :: String.t(), meta :: map()) ::
              {:ok, handle} | {:error, term()}

  @doc """
  Reattach to a conversation named in `meta`.

  Called on restore and after a crash. Both backends locate a conversation by
  uuid alone — no working directory needed — so `meta` only has to carry the id.

  Codex enforces a single writer per thread with a lock file that survives an
  ungraceful kill, so this is also where a stale lock belonging to *our own*
  session gets cleared. See `docs/backends.md` §6.2.
  """
  @callback resume(session_id :: String.t(), meta :: map()) ::
              {:ok, handle} | {:error, term()}

  @doc """
  Start one turn with `text`.

  Returns as soon as the turn is under way; output arrives asynchronously and is
  fed back through `decode/2`.
  """
  @callback run_turn(handle, text :: String.t()) :: {:ok, handle} | {:error, term()}

  @doc """
  Inject `text` into the turn that is currently running.

  Must fail rather than silently start a new turn when there is nothing to join:
  the session falls back to `run_turn/2` on an error, and a message delivered to
  the wrong turn is worse than one delivered late.
  """
  @callback steer(handle, text :: String.t()) :: {:ok, handle} | {:error, term()}

  @doc """
  Abort the running turn, equivalent to pressing escape.

  The queue is not this callback's business: the session keeps it and waits for
  the user to type before draining it, so that stopping the agent never makes
  something else immediately start.

  A turn aborted this way must surface as a `:turn_aborted` event, never as an
  error. Claude Code reports a graceful interrupt as `result/error_during_execution`,
  which is a lie, so its `decode/2` swallows the result of an interrupt it asked
  for and the session reports the stop itself. (Killing would avoid the lie but
  throw away the warm process.)
  """
  @callback interrupt(handle) :: {:ok, handle} | {:error, term()}

  @doc """
  Translate one raw backend message into events and deltas.

  `message` is whatever the session received and did not handle itself: a port
  message for Claude Code, a decoded JSON-RPC notification for Codex. Returning
  `:ignore` means "not mine", which is how one session can coexist with the
  shared codex server's traffic.
  """
  @callback decode(handle, message :: term()) :: {:ok, handle, [out]} | :ignore

  @doc """
  The fields to write into the session's `meta.json`.

  The handle is opaque, so the session cannot know which parts of it identify a
  conversation and have to survive a restart. Whatever comes back here is merged
  into the header and handed straight back to `resume/2`.
  """
  @callback persist(handle) :: map()

  @doc """
  Drop whatever this handle is holding warm, keeping it usable.

  Claude Code keeps a ~275 MB process alive between turns so that the second and
  later turns start in 0.02 s instead of 6 s (measured). That is the right trade
  while someone is working and pure waste once they walk away, so the session
  calls this on an idle timer; the next `run_turn/2` pays the cold start again.

  For Codex it is a no-op: its app-server is shared by every session and lives
  for as long as the node.
  """
  @callback release(handle) :: {:ok, handle}

  @doc """
  Release everything this handle owns.

  For Claude Code that means making sure the whole process tree is gone — it is
  three levels deep (shim, launcher, runtime) and killing the outermost does not
  reliably take the others. For Codex it means dropping the thread's writer lock
  so the next resume is not refused.
  """
  @callback stop(handle) :: :ok

  @doc """
  The module implementing `kind`.

  Configurable so tests can substitute a stub without spawning anything:

      config :loom, Loom.Agent, backends: %{claude_code: MyStub}
  """
  @spec impl(kind) :: module()
  def impl(kind) when kind in [:claude_code, :codex] do
    configured = Application.get_env(:loom, Loom.Agent, [])[:backends] || %{}
    Map.get(configured, kind, default_impl(kind))
  end

  defp default_impl(:claude_code), do: Loom.Agent.Backend.ClaudeCode
  defp default_impl(:codex), do: Loom.Agent.Backend.Codex

  @doc """
  Parse a persisted or user-supplied backend name.

  Returns `:error` rather than defaulting, because guessing would silently bind a
  session to the wrong engine — and the binding is permanent (the conversation
  lives in that engine's own store, so there is nothing to migrate).
  """
  @spec parse(term()) :: {:ok, kind} | :error
  def parse(kind) when kind in [:claude_code, :codex], do: {:ok, kind}
  def parse("claude_code"), do: {:ok, :claude_code}
  def parse("codex"), do: {:ok, :codex}
  def parse(_other), do: :error

  @doc "Human-facing label for the session list."
  @spec label(kind) :: String.t()
  def label(:claude_code), do: "Claude Code"
  def label(:codex), do: "Codex"

  @doc """
  Read one field out of a persisted header, by atom or string key.

  Both forms genuinely occur. `Store.read_meta/1` atomises keys with
  `String.to_existing_atom/1` and falls back to the string when the atom does
  not exist — and Elixir loads modules lazily, so at boot the adapter module
  that gives `:cc_session_id` or `:codex_thread_id` its only mention may not be
  loaded yet. The header then comes back with string keys and a plain
  `meta[:cc_session_id]` reads `nil`, which looks exactly like "this session was
  never bound to a backend".

  That cost a real session: a restart reported `no cc_session_id recorded` for a
  conversation whose id was sitting in the file.
  """
  @spec meta_get(map(), atom()) :: term()
  def meta_get(meta, key) when is_map(meta) and is_atom(key) do
    case Map.fetch(meta, key) do
      {:ok, value} -> value
      :error -> Map.get(meta, Atom.to_string(key))
    end
  end
end
