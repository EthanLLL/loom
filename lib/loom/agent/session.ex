defmodule Loom.Agent.Session do
  @moduledoc """
  One conversation: one GenServer bound for life to one Claude Code session or
  one Codex thread.

  Loom no longer runs an agent loop. This process owns everything the backend
  does not: the queue of user messages, event numbering, the replayable
  transcript, the title, and status. The agent loop, the tools, the context
  window and the system prompt all belong to the backend now — see
  `docs/backends.md`.

  ## A message typed mid-turn joins that turn

  Both backends inject a mid-turn message into the running turn — Claude Code at
  the next tool-result boundary, Codex immediately via `turn/steer` (both
  measured; see `Loom.Agent.Backend`). So a message that arrives while the agent
  is working is handed straight over rather than queued: the point of typing "no,
  not like that" is that it lands before the work is finished.

  The queue therefore exists for exactly one case — `:interrupted`, where no turn
  is running to join. Those messages wait, and go out merged with whatever the
  user types next; three things said at once should reach the model together,
  because the third is usually the one that overrules the first two.

  If steering fails (Codex refuses when the turn ended under us) the message
  falls back to the queue and the next turn carries it. Late beats lost.

  ## Interrupting parks the queue instead of draining it

  `interrupt/1` stops the turn and moves to `:interrupted`, whose only purpose is
  to suppress the "idle and the queue is not empty, so start a turn" rule. If an
  interrupt drained the queue, stopping the agent would immediately start
  something else, which is not what pressing escape means.

  ## The backend is kept warm, then let go

  Claude Code holds a ~275 MB process so that later turns start in 0.02 s instead
  of 6 s. That is worth paying while someone is working and pure waste once they
  walk away, so a timer releases it after `@idle_release_ms` with no turn. The
  conversation is unaffected — it lives in the backend's own store — the next
  turn just pays the cold start again. For Codex this is a no-op.

  `/reload` (`Loom.Agent.reload_backends/0`) lets every session's backend go at
  once instead of on the timer, so changed config is read on the next turn. A
  session that is mid-turn sets `reload_after_turn` and lets go when it ends.

  To continue, the user types. That submission merges with whatever was parked,
  so there is no resume button, no "continue or discard" prompt, and no second
  code path — recovery *is* an ordinary submit.

  ## A restart mid-turn is an interrupt, not a resume

  The old loop could pick a turn back up after a crash because it owned the loop.
  A backend turn is a child process of this node, so it dies with the node and
  cannot be rejoined. Re-submitting is worse than it looks: the user's message is
  already in the backend's own history, so the model would see it twice.

  So a session found mid-turn on disk comes back `:interrupted` with its queue
  intact, and says so. The user supplies the next message and continues, exactly
  as after a deliberate interrupt. Codex daemon mode would restore the old
  behaviour and is noted as future work.

  ## Fan-out to several devices

  Unchanged, and still the reason this process exists at all: every state change
  becomes an event with a monotonic `seq`, appended to `events.jsonl` and
  broadcast on `"agent:<id>"`. Clients join with the last `seq` they saw and get
  only what they missed. Transient deltas go out on the same topic as
  `{:agent_delta, id, delta}` and are never persisted — a client that missed one
  gets the authoritative event instead.

  Deltas carry their own monotonic `delta_seq` for the same reason events carry
  `seq`: so a client can tell a delta it has already applied from a new one.
  Text deltas are *appended*, so applying one twice visibly corrupts the output
  — and double delivery really happens. phoenix.js skips the leave push when a
  channel has not finished joining (it fakes a local "ok" instead), so a client
  that mounts and immediately remounts — React StrictMode does exactly this —
  leaves a channel process alive on the server, subscribed and pushing. Events
  survived it because `seq` deduplicated them; deltas interleaved the same text
  with itself.
  """
  use GenServer, restart: :transient

  require Logger

  alias Loom.Agent.Backend
  alias Loom.Agent.Files
  alias Loom.Agent.Output
  alias Loom.Agent.Store

  # How many events stay in memory for replay. A client that has been away
  # longer gets `truncated_before` and reloads.
  @transcript_limit 500

  @title_limit 80

  # How long a finished session keeps its backend warm. Long enough to cover
  # reading the output and typing a follow-up; short enough that a session left
  # open overnight costs nothing.
  @idle_release_ms :timer.minutes(15)

  # What counts as the session being used, for `last_active_at`. Not `:status`:
  # a restart restores every session, and must not make them all "just now".
  @activity [:user, :assistant_text, :turn_done]

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :id)))
  end

  @doc """
  Submit a user message.

  Always accepted. Returns `{:ok, :started}` if it begins a turn immediately or
  `{:ok, :queued}` if it is waiting for the current turn — or for the user to
  continue, when the session is `:interrupted`.

  `opts` accepts `:origin` (which device sent it), `:client_msg_id` (so the
  sender can reconcile its optimistic bubble with the broadcast one) and
  `:files` — paths of this session's uploaded attachments, which are appended to
  the message the backend sees but kept out of the one that is displayed.
  """
  def submit(id, text, opts \\ []), do: GenServer.call(via(id), {:submit, text, opts})

  @doc """
  Stop the running turn, like pressing escape.

  Queued messages are kept, not sent. See the moduledoc.
  """
  def interrupt(id), do: GenServer.call(via(id), :interrupt)

  @doc """
  Discard one queued message by its position, oldest first.

  Worth having because a message queued before an interrupt was written for a
  trajectory that no longer exists, and the alternative is forcing the user to
  send it anyway.
  """
  def drop_queued(id, index), do: GenServer.call(via(id), {:drop_queued, index})

  @doc """
  Rename the session.

  Local to loom: the title is a sidebar label, not conversation state, so it is
  never pushed to the backend. That also avoids inventing an answer to "who wins
  when the backend renames it too".
  """
  def rename(id, title), do: GenServer.call(via(id), {:rename, title})

  @doc """
  Attach for replay. Returns the session's metadata plus every event after
  `since_seq` (pass 0 for the whole retained transcript).
  """
  def attach(id, since_seq \\ 0), do: GenServer.call(via(id), {:attach, since_seq})

  @doc "Session metadata without the transcript."
  def info(id), do: GenServer.call(via(id), :info)

  def topic(id), do: "agent:#{id}"
  def via(id), do: {:via, Registry, {Loom.Agent.Registry, id}}

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # Trap exits so `terminate/2` runs on a supervisor shutdown — that is where
    # the backend is torn down. Without it a stopped session leaves a `claude`
    # process running, or a codex thread holding its writer lock.
    Process.flag(:trap_exit, true)

    id = Keyword.fetch!(opts, :id)

    # State on disk always wins over whatever the caller asked for. Two paths
    # land here and both must reattach rather than start over: the explicit
    # restore at boot, and the supervisor restarting us with the *original* spec
    # after a crash. Treating the second as new would bind a second backend
    # conversation to a session that already has one.
    case Store.read_meta(id) do
      {:ok, meta} ->
        restore(id, meta)

      :error ->
        if Keyword.get(opts, :restore, false) do
          {:stop, {:no_such_session, id}}
        else
          start_fresh(id, opts)
        end
    end
  end

  defp start_fresh(id, opts) do
    with {:ok, backend} <- requested_backend(opts),
         {:ok, logs} <- Store.open_logs(id) do
      now = System.system_time(:millisecond)

      state = %{
        blank_state(id)
        | backend: backend,
          title: Keyword.get(opts, :title),
          created_at: now,
          last_active_at: now,
          logs: logs,
          outputs: outputs(id)
      }

      case Backend.impl(backend).start(id, backend_meta(id, opts)) do
        {:ok, handle} ->
          state = %{state | handle: handle}
          persist_meta(state)
          {:ok, state}

        {:error, reason} ->
          Store.close_logs(logs)
          {:stop, {:backend_failed, reason}}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # No default on purpose. The binding is permanent — the conversation lives in
  # the backend's own store, so there is nothing to migrate — and guessing would
  # silently commit the user to the wrong engine.
  defp requested_backend(opts) do
    case Backend.parse(Keyword.get(opts, :backend)) do
      {:ok, backend} -> {:ok, backend}
      :error -> {:error, {:backend_required, Keyword.get(opts, :backend)}}
    end
  end

  # `:cwd` is only ever a test or operator override. A session has no project
  # root; the backend falls back to `:workspace` (or the user's home).
  defp backend_meta(id, opts) do
    %{
      cc_cwd: Keyword.get(opts, :cwd),
      codex_cwd: Keyword.get(opts, :cwd),
      instructions: Output.instructions(id)
    }
  end

  # The directory as the session starts. Made first, so the agent can write
  # straight into it; snapshotted so that only what a turn produces is
  # announced — a restart must not re-offer every file made last week.
  defp outputs(id) do
    Output.ensure_dir(id)
    Output.snapshot(id)
  end

  defp restore(id, meta) do
    with {:ok, backend} <- recorded_backend(meta),
         {:ok, logs} <- Store.open_logs(id),
         {:ok, handle} <-
           reattach(backend, id, Map.put(meta, :instructions, Output.instructions(id)), logs) do
      transcript = Store.read_events(id, @transcript_limit)

      state = %{
        blank_state(id)
        | backend: backend,
          handle: handle,
          title: meta[:title],
          created_at: meta[:created_at],
          last_active_at: last_active(transcript) || meta[:created_at],
          transcript: transcript,
          seq: meta[:seq] || 0,
          queue: restore_queue(meta[:queue]),
          usage: meta[:usage],
          context_tokens: meta[:context_tokens] || 0,
          context_window: meta[:context_window],
          turns: meta[:turns] || 0,
          logs: logs,
          outputs: outputs(id)
      }

      if meta[:status] in ["running", "starting"] do
        # It was mid-turn when the node stopped. The turn went with it and
        # cannot be rejoined, so say so and wait for the user rather than
        # re-sending a message the backend has already recorded.
        {:ok, interrupted(state, "the session was interrupted by a restart")}
      else
        state = %{state | status: restore_status(meta[:status])}
        announce(state)
        {:ok, state}
      end
    else
      {:error, reason} -> {:stop, {:restore_failed, reason}}
    end
  end

  # A header with no usable `backend` cannot be reattached to anything. Refusing
  # with a reason beats guessing an engine and opening an empty conversation
  # under the old title — and beats crashing, which is what an unmatched `:error`
  # in the `with` above used to do.
  defp recorded_backend(meta) do
    case Backend.parse(Backend.meta_get(meta, :backend)) do
      {:ok, backend} -> {:ok, backend}
      :error -> {:error, {:no_backend_recorded, meta[:backend]}}
    end
  end

  defp reattach(backend, id, meta, logs) do
    case Backend.impl(backend).resume(id, meta) do
      {:ok, handle} ->
        {:ok, handle}

      {:error, reason} ->
        Store.close_logs(logs)
        {:error, reason}
    end
  end

  defp restore_status("interrupted"), do: :interrupted
  defp restore_status(_other), do: :idle

  defp restore_queue(queue) when is_list(queue), do: Enum.filter(queue, &is_binary/1)
  defp restore_queue(_other), do: []

  defp blank_state(id) do
    %{
      id: id,
      backend: nil,
      # Backend-private. Only `Backend.persist/1` knows what of it to keep.
      handle: nil,
      title: nil,
      created_at: nil,
      # When the last message went either way; orders the sidebar. Derived from
      # the transcript on restore rather than stored.
      last_active_at: nil,
      status: :idle,
      # Normalized events for clients, newest first.
      transcript: [],
      seq: 0,
      # Deltas are not persisted, so this restarts at 0 on every restore — which
      # is fine: a client that reattaches also discards its streaming buffers.
      delta_seq: 0,
      truncated_before: nil,
      # User messages waiting for the current turn to end, oldest first. On disk
      # too: a restart must not drain a queue the user deliberately parked.
      queue: [],
      logs: nil,
      # Straight from the backend's own report. No token counting here any more.
      usage: nil,
      context_tokens: 0,
      # The model's context window, as the backend reports it. Codex sends it
      # outright; Claude Code carries it on `modelUsage`.
      context_window: nil,
      turns: 0,
      # Timer that releases the warm backend process once nothing is happening.
      release_timer: nil,
      # `/reload` arrived mid-turn: let the backend go as soon as the turn ends.
      reload_after_turn: false,
      # The output directory as of the last turn's end. See `Loom.Agent.Output`.
      outputs: %{}
    }
  end

  # ── Calls ───────────────────────────────────────────────────────────────

  @impl true
  def handle_call({:submit, text, opts}, _from, state) do
    text = to_string(text)

    # The client sends back paths that `Files.store/2` handed it. Checking them
    # against this session's own directory is the one validation that matters:
    # the model reads whatever path we name. See `Loom.Agent.Files`.
    case Files.verify(state.id, Keyword.get(opts, :files, [])) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, files} ->
        # An attachment on its own is a message. Dragging in a screenshot and
        # pressing send, with nothing typed, is a normal way to ask about it.
        cond do
          String.trim(text) == "" and files == [] -> {:reply, {:error, :empty}, state}
          reload?(text) and files == [] -> reload(state, text, opts)
          command?(text, "/cron") and files == [] -> list_cron(state, text, opts)
          true -> accept(state, text, files, opts)
        end
    end
  end

  def handle_call(:interrupt, _from, %{status: status} = state)
      when status in [:idle, :interrupted] do
    {:reply, :ok, state}
  end

  def handle_call(:interrupt, _from, state) do
    case Backend.impl(state.backend).interrupt(state.handle) do
      {:ok, handle} ->
        # Whatever the turn wrote before it was stopped is still the user's.
        state = collect_outputs(%{state | handle: handle})
        {:reply, :ok, interrupted(state, "interrupted")}

      {:error, reason} ->
        # The turn may well be dead anyway, but claiming it stopped when the
        # backend says otherwise would leave the UI lying.
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:drop_queued, index}, _from, state) do
    if index >= 0 and index < length(state.queue) do
      state = Map.update!(state, :queue, &List.delete_at(&1, index))
      {:reply, :ok, persist_and_broadcast_queue(state)}
    else
      {:reply, {:error, :out_of_range}, state}
    end
  end

  def handle_call({:rename, title}, _from, state) do
    title = title |> to_string() |> String.trim() |> String.slice(0, @title_limit)

    if title == "" do
      {:reply, {:error, :empty}, state}
    else
      state = emit(%{state | title: title}, :renamed, %{title: title})
      persist_meta(state)
      {:reply, :ok, state}
    end
  end

  def handle_call({:attach, since_seq}, _from, state) do
    events =
      state.transcript
      |> Enum.take_while(&(&1.seq > since_seq))
      |> Enum.reverse()

    {:reply,
     {:ok,
      %{
        meta: meta(state),
        events: events,
        last_seq: state.seq,
        truncated_before: state.truncated_before
      }}, state}
  end

  def handle_call(:info, _from, state), do: {:reply, meta(state), state}

  # ── Backend output ──────────────────────────────────────────────────────

  @impl true
  def handle_info(:release_backend, %{status: status} = state)
      when status in [:starting, :running] do
    # A turn started between the timer firing and this landing. Leave it alone
    # and try again when that turn ends.
    {:noreply, %{state | release_timer: nil}}
  end

  def handle_info(:release_backend, state) do
    {:noreply, release_backend(state)}
  end

  def handle_info(:reload_backend, %{status: status} = state)
      when status in [:starting, :running] do
    {:noreply, %{state | reload_after_turn: true}}
  end

  def handle_info(:reload_backend, state) do
    {:noreply, release_backend(state)}
  end

  def handle_info({:EXIT, _from, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    case Backend.impl(state.backend).decode(state.handle, message) do
      {:ok, handle, out} ->
        {:noreply, consume(%{state | handle: handle}, out)}

      :ignore ->
        Logger.debug("Loom.Agent.Session #{state.id} ignoring #{inspect(message)}")
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Take the backend down with us: a `claude` process left running would keep
    # editing files for a conversation nobody is watching, and a codex thread
    # left claimed cannot be reopened.
    if state.handle, do: Backend.impl(state.backend).stop(state.handle)

    # Record that we are not mid-turn, so a restart does not report a
    # deliberately stopped session as interrupted. A hard crash skips this and
    # leaves `status` as it was — which is what makes the restart notice.
    write_meta(%{state | status: settled_status(state)})
    Store.close_logs(state.logs)
    :ok
  catch
    _, _ -> :ok
  end

  # An interrupted session stays interrupted across a restart: its queue is
  # parked and the user has not continued yet.
  defp settled_status(%{status: :interrupted}), do: :interrupted
  defp settled_status(_state), do: :idle

  # ── The turn ────────────────────────────────────────────────────────────

  # Loom's own command, never sent to a backend. Only the whole message counts,
  # so a sentence that mentions /reload is still a sentence.
  defp reload?(text), do: command?(text, "/reload")

  defp command?(text, command), do: String.trim(text) == command

  # Shown like any message (the client is waiting for its `:user` event to
  # replace the optimistic bubble), then answered by loom itself. The backend
  # never sees it, so the turn state and the queue are untouched.
  defp reload(state, text, opts) do
    Loom.Agent.reload_backends()
    state = state |> echo(text, opts) |> emit(:reload_requested, %{})
    {:reply, {:ok, :reloaded}, state}
  end

  # `/cron` lists every scheduled job, in whichever session it is typed. Jobs
  # are made by an agent over `bin/loom rpc`; see `Loom.Cron`.
  defp list_cron(state, text, opts) do
    jobs =
      try do
        Loom.Cron.list()
      catch
        :exit, _ -> []
      end

    state = state |> echo(text, opts) |> emit(:cron_jobs, %{jobs: jobs})
    {:reply, {:ok, :listed}, state}
  end

  defp echo(state, text, opts) do
    emit(state, :user, %{
      text: text,
      files: [],
      origin: Keyword.get(opts, :origin, "unknown"),
      client_msg_id: Keyword.get(opts, :client_msg_id),
      status: :sent
    })
  end

  # A submitted message, once its attachments have been vouched for.
  defp accept(state, text, files, opts) do
    state =
      state
      |> maybe_title(if String.trim(text) == "", do: Files.title(files), else: text)
      |> emit(:user, %{
        text: text,
        # Structured rather than folded into `text`, so a bubble can show
        # `shot.png` as a chip instead of an absolute path.
        files: files,
        origin: Keyword.get(opts, :origin, "unknown"),
        client_msg_id: Keyword.get(opts, :client_msg_id),
        status: :sent
      })

    # What the backend receives differs from what is displayed: it needs the
    # paths, the user does not want to read them.
    message = Files.prompt(text, files)

    case state.status do
      status when status in [:starting, :running] ->
        # Hand it straight over: both backends inject it into the turn that is
        # running. Queuing it would waste the one thing that makes typing
        # mid-turn useful. It only joins the queue if steering is refused.
        steer(state, message)

      _ ->
        # Covers `:interrupted` as well as `:idle`: typing is how an
        # interrupted session continues, and anything parked goes out merged
        # with this message.
        state = Map.update!(state, :queue, &(&1 ++ [message]))
        {:reply, {:ok, :started}, drain(state)}
    end
  end

  defp consume(state, out), do: Enum.reduce(out, state, &apply_out(&2, &1))

  defp apply_out(state, {:delta, delta}) do
    # Not persisted — deltas are a typewriter effect and the authoritative event
    # follows under the same `block_id`. But numbered, so a client can drop one
    # it has already applied; see the moduledoc.
    delta_seq = state.delta_seq + 1
    delta = Map.put(delta, :delta_seq, delta_seq)

    Phoenix.PubSub.broadcast(Loom.PubSub, topic(state.id), {:agent_delta, state.id, delta})
    %{state | delta_seq: delta_seq}
  end

  defp apply_out(state, {:event, :status, %{status: :running}}) do
    set_status(state, :running)
  end

  defp apply_out(state, {:event, :turn_done, payload}) do
    state
    |> record_usage(payload)
    |> collect_outputs()
    |> emit(:turn_done, Map.take(payload, [:stop_reason, :context_tokens, :context_window]))
    |> finish_turn()
  end

  defp apply_out(state, {:event, :turn_failed, payload}) do
    state
    |> collect_outputs()
    |> emit(:error, %{message: failure_message(payload)})
    |> finish_turn()
  end

  defp apply_out(state, {:event, kind, payload}), do: emit(state, kind, payload)

  defp failure_message(%{reason: reason}) when is_binary(reason), do: reason
  defp failure_message(payload), do: inspect(payload)

  # A finished turn drains the queue. This is the only place a turn starts on
  # its own, and the reason `:interrupted` has to be a distinct status: it must
  # not reach here.
  defp finish_turn(state) do
    state = %{state | turns: state.turns + 1}

    if state.queue == [] do
      state |> set_status(:idle) |> announce_turn_end() |> schedule_release()
    else
      drain(state)
    end
  end

  # Hand a message to the turn that is running. On failure it goes into the
  # queue instead — Codex refuses to steer a turn that ended under us, and a
  # message delivered late is better than one dropped.
  defp steer(state, text) do
    case Backend.impl(state.backend).steer(state.handle, text) do
      {:ok, handle} ->
        {:reply, {:ok, :steered}, cancel_release(%{state | handle: handle})}

      {:error, _reason} ->
        state = Map.update!(state, :queue, &(&1 ++ [text]))
        {:reply, {:ok, :queued}, persist_and_broadcast_queue(state)}
    end
  end

  defp drain(%{queue: []} = state), do: set_status(state, :idle)

  defp drain(state) do
    # The whole queue becomes one message. See the moduledoc.
    queue = state.queue
    text = Enum.join(queue, "\n\n")

    state = cancel_release(state)

    case Backend.impl(state.backend).run_turn(state.handle, text) do
      {:ok, handle} ->
        # `:starting` rather than `:running`: Claude Code takes seconds to boot
        # before it says anything, and a UI with no state for that gap looks
        # hung. The backend's own status event moves us to `:running`.
        set_status(%{state | handle: handle, queue: []}, :starting)

      {:error, reason} ->
        # The queue is cleared only on success. Dropping the user's message
        # because the backend hiccuped loses work they cannot get back, and
        # leaving it queued means the next submit carries it along.
        state
        |> emit(:error, %{message: "could not start the turn: #{inspect(reason)}"})
        |> persist_and_broadcast_queue()
        |> set_status(:idle)
    end
  end

  defp interrupted(state, message) do
    state
    |> emit(:status, %{status: :interrupted, queued: length(state.queue), message: message})
    |> set_status(:interrupted)
    |> schedule_release()
  end

  # For notifications (`Loom.Push`). The reply is the turn's last text, found by
  # reading back to the message that started it; an error after it wins, since
  # that is how the turn actually ended.
  defp announce_turn_end(state) do
    outcome =
      Enum.find_value(state.transcript, {:ok, nil}, fn
        %{kind: :error, payload: %{message: message}} -> {:error, message}
        %{kind: :assistant_text, payload: %{text: text}} -> {:ok, text}
        %{kind: :user} -> {:ok, nil}
        _ -> nil
      end)

    Phoenix.PubSub.broadcast(
      Loom.PubSub,
      Loom.Agent.turns_topic(),
      {:turn_ended, state.id, %{title: state.title, outcome: outcome}}
    )

    state
  end

  # Announce what the turn left in the output directory. Before the turn's own
  # closing event, so the card sits with the reply that made the files.
  defp collect_outputs(state) do
    now = Output.snapshot(state.id)

    case Output.changes(state.outputs, now) do
      %{files: []} -> %{state | outputs: now}
      payload -> emit(%{state | outputs: now}, :output_files, payload)
    end
  end

  # ── Keeping the backend warm ────────────────────────────────────────────

  defp cancel_release(%{release_timer: nil} = state), do: state

  defp cancel_release(state) do
    Process.cancel_timer(state.release_timer)
    %{state | release_timer: nil}
  end

  defp release_backend(%{handle: nil} = state), do: %{state | reload_after_turn: false}

  defp release_backend(state) do
    state = cancel_release(state)
    {:ok, handle} = Backend.impl(state.backend).release(state.handle)
    %{state | handle: handle, reload_after_turn: false}
  end

  defp schedule_release(%{reload_after_turn: true} = state), do: release_backend(state)

  defp schedule_release(state) do
    state = cancel_release(state)
    %{state | release_timer: Process.send_after(self(), :release_backend, @idle_release_ms)}
  end

  defp record_usage(state, payload) do
    %{
      state
      | usage: payload[:usage] || state.usage,
        context_tokens: payload[:context_tokens] || state.context_tokens,
        context_window: payload[:context_window] || state.context_window
    }
  end

  # ── Events ──────────────────────────────────────────────────────────────

  defp emit(state, kind, payload) do
    seq = state.seq + 1

    event = %{
      seq: seq,
      at: System.system_time(:millisecond),
      kind: kind,
      payload: payload
    }

    Store.append_event(state.logs, event)
    Phoenix.PubSub.broadcast(Loom.PubSub, topic(state.id), {:agent_event, state.id, event})

    {transcript, truncated_before} = retain([event | state.transcript], state.truncated_before)
    state = %{state | seq: seq, transcript: transcript, truncated_before: truncated_before}

    cond do
      kind not in @activity ->
        state

      # A message moves the session to the top of the list at once. Turn ends
      # change the status and are announced by that anyway.
      kind == :user ->
        state = %{state | last_active_at: event.at}
        announce(state)
        state

      true ->
        %{state | last_active_at: event.at}
    end
  end

  defp last_active(transcript) do
    Enum.find_value(transcript, fn event -> event.kind in @activity && event.at end)
  end

  defp retain(transcript, truncated_before) do
    if length(transcript) > @transcript_limit do
      kept = Enum.take(transcript, @transcript_limit)
      oldest = List.last(kept)
      {kept, max(truncated_before || 0, oldest.seq - 1)}
    else
      {transcript, truncated_before}
    end
  end

  # Every transition is broadcast and written to the header.
  #
  # The broadcast is what lets a second device show the right thing: a phone
  # that joins mid-turn learns the status from the snapshot, but from then on
  # `starting → running → idle` only reaches it as events. The header write is
  # what a restart reads to decide whether the session was mid-turn.
  defp set_status(state, status) do
    if state.status == status do
      state
    else
      state =
        emit(%{state | status: status}, :status, %{status: status, queued: length(state.queue)})

      persist_meta(state)
      state
    end
  end

  # Queue changes are not status changes, but clients still have to see them —
  # a queued bubble has to stop looking pending once it goes out.
  defp persist_and_broadcast_queue(state) do
    state = emit(state, :queue, %{queued: length(state.queue), messages: state.queue})
    persist_meta(state)
    state
  end

  # Every header write is also a sidebar update: the header is exactly what
  # the session list shows, so the two change together. See `announce/1`.
  defp persist_meta(state) do
    write_meta(state)
    announce(state)
  end

  # Not from `terminate/2`, which only writes. A session going away is announced
  # by `Loom.Agent.stop_session/1` as a removal, and a summary sent on the way
  # out would race it.
  defp announce(state) do
    Phoenix.PubSub.broadcast(
      Loom.PubSub,
      Loom.Agent.lobby_topic(),
      {:agent_summary, meta(state)}
    )
  end

  defp write_meta(state) do
    base = %{
      id: state.id,
      backend: state.backend,
      title: state.title,
      created_at: state.created_at,
      status: state.status,
      seq: state.seq,
      queue: state.queue,
      usage: state.usage,
      context_tokens: state.context_tokens,
      context_window: state.context_window,
      turns: state.turns
    }

    # The handle is opaque, so the backend decides what identifies its
    # conversation. Whatever it returns comes straight back on resume.
    backend_fields =
      if state.handle, do: Backend.impl(state.backend).persist(state.handle), else: %{}

    Store.write_meta(state.id, Map.merge(base, backend_fields))
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Name the session after its first message. Without this a session list shows
  # nothing but opaque ids, and the alternative — joining every session to read
  # its transcript — defeats the point of a cheap header read.
  defp maybe_title(%{title: nil} = state, text) when is_binary(text) do
    title =
      text
      |> String.split("\n", parts: 2)
      |> List.first()
      |> String.trim()
      |> String.slice(0, @title_limit)

    if title == "", do: state, else: %{state | title: title}
  end

  defp maybe_title(state, _text), do: state

  defp meta(state) do
    %{
      id: state.id,
      backend: state.backend,
      backend_label: Backend.label(state.backend),
      title: state.title,
      created_at: state.created_at,
      last_active_at: state.last_active_at,
      status: state.status,
      queued: length(state.queue),
      queue: state.queue,
      usage: state.usage,
      context_tokens: state.context_tokens,
      context_window: state.context_window,
      turns: state.turns,
      # Orders summaries: the lobby can deliver one that is older than the
      # list a client just joined with, and `seq` says which is newer.
      seq: state.seq
    }
  end
end
