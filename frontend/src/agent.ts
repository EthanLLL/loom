import type { AgentFile, AgentInfo, AgentStatus, AgentUsage, OutputFile } from "./api"

/**
 * The client half of the agent protocol.
 *
 * The server sends two kinds of message and the difference is the whole design:
 *
 *   event  — has a `seq`, is persisted, is replayed on reconnect. The truth.
 *   delta  — no `seq`, transient, never replayed. The typewriter.
 *
 * So a delta is appended to a placeholder keyed by its `block_id`, and when the
 * event carrying that same `block_id` arrives it *replaces* the placeholder
 * wholesale. A stream that dies mid-sentence therefore costs nothing: the
 * placeholder is overwritten by the next event, or dropped on reconnect and
 * refetched from `since_seq`.
 *
 * Everything here is a pure function over `Transcript` so the rules are in one
 * place rather than spread through components.
 */

export type AgentEvent = {
  seq: number
  at: number
  kind: string
  payload: Record<string, unknown>
}

export type AgentDelta = {
  // Monotonic per session. Deltas are appended, so applying one twice visibly
  // corrupts the output — and double delivery happens for real (see
  // `applyDelta`), which is why they are numbered like events are.
  delta_seq: number
  block_id: string
  type:
    | "block_start"
    | "text"
    | "thinking"
    | "tool_use_start"
    | "tool_output"
    | "block_end"
  chunk?: string
  block_type?: string
  name?: string
  id?: string
}

export type Snapshot = {
  meta: AgentInfo
  events: AgentEvent[]
  last_seq: number
  truncated_before: number | null
}

/** A block still arriving as deltas, with no authoritative event yet. */
type StreamingBlock = {
  blockId: string
  kind: "text" | "thinking" | "tool_use"
  text: string
  name?: string
}

/**
 * Output streaming out of a tool that is still running, keyed by the tool
 * card's `block_id`.
 *
 * Separate from `streaming` because a tool card is usually an *event* already
 * (`tool_use` arrives before the output does), so this has to survive the
 * delta→event handover that clears `streaming`. It is cleared by `tool_result`
 * instead, which carries the authoritative output.
 */
type ToolStream = { blockId: string; text: string }

/** A message we have sent but whose `:user` event has not come back yet. */
type PendingMessage = {
  clientMsgId: string
  text: string
  files: AgentFile[]
}

export type Transcript = {
  events: AgentEvent[]
  lastSeq: number
  truncatedBefore: number | null
  streaming: StreamingBlock[]
  lastDeltaSeq: number
  toolStreams: ToolStream[]
  pending: PendingMessage[]
  status: AgentStatus
  usage: AgentUsage | null
  contextTokens: number
  contextWindow: number | null
  turns: number
  // The parked messages themselves, so an interrupted session can show what is
  // waiting and offer to drop a line that no longer applies.
  queue: string[]
}

export const emptyTranscript: Transcript = {
  events: [],
  lastSeq: 0,
  truncatedBefore: null,
  streaming: [],
  lastDeltaSeq: 0,
  toolStreams: [],
  pending: [],
  status: "idle",
  usage: null,
  contextTokens: 0,
  contextWindow: null,
  turns: 0,
  queue: [],
}

/**
 * Fold a join reply in.
 *
 * Pass `previous` when this is a *re*join: the reply then only carries events
 * after `since_seq`, so replacing state with it would throw the history away.
 * Keeping `lastSeq` also makes `applyEvent` drop anything we already had.
 *
 * Streaming buffers are always discarded — a half-written placeholder has no
 * authoritative counterpart yet, and everything real is in `events`.
 */
export function applySnapshot(
  snapshot: Snapshot,
  previous?: Transcript,
): Transcript {
  const base: Transcript = {
    ...(previous ?? emptyTranscript),
    streaming: [],
    lastDeltaSeq: 0,
    toolStreams: [],
    status: snapshot.meta.status,
    contextTokens: snapshot.meta.context_tokens ?? 0,
    contextWindow: snapshot.meta.context_window ?? null,
    usage: snapshot.meta.usage ?? null,
    turns: snapshot.meta.turns ?? 0,
    queue: snapshot.meta.queue ?? [],
    truncatedBefore: snapshot.truncated_before,
  }
  return snapshot.events.reduce(applyEvent, base)
}

export function applyEvent(t: Transcript, event: AgentEvent): Transcript {
  // The join snapshot and the broadcast stream overlap by design (we subscribe
  // after snapshotting), so duplicates are expected rather than exceptional.
  if (event.seq <= t.lastSeq) return t

  const p = event.payload
  const blockId = p.block_id as string | undefined
  const clientMsgId = p.client_msg_id as string | undefined

  return {
    ...t,
    events: [...t.events, event],
    lastSeq: event.seq,
    // This is the delta→event handover: the event supersedes the placeholder
    // its chunks were going into.
    streaming: blockId
      ? t.streaming.filter((b) => b.blockId !== blockId)
      : t.streaming,
    // A tool's streamed output is only superseded by its *result*, not by the
    // `tool_use` event — that one arrives before any output exists.
    toolStreams:
      event.kind === "tool_result"
        ? t.toolStreams.filter((s) => s.blockId !== String(p.id))
        : t.toolStreams,
    pending:
      event.kind === "user" && clientMsgId
        ? t.pending.filter((m) => m.clientMsgId !== clientMsgId)
        : t.pending,
    status: statusAfter(t.status, event),
    queue: queueAfter(t.queue, event),
    usage: (p.usage as AgentUsage | undefined) ?? t.usage,
    contextTokens: (p.context_tokens as number | undefined) ?? t.contextTokens,
    contextWindow: (p.context_window as number | undefined) ?? t.contextWindow,
    turns: event.kind === "turn_done" ? t.turns + 1 : t.turns,
  }
}

function statusAfter(current: AgentStatus, event: AgentEvent): AgentStatus {
  if (event.kind !== "status") return current
  const next = event.payload.status as AgentStatus
  // Every status the server sends now is a resting state, so unlike the old
  // protocol there is nothing to filter out.
  return next
}

/**
 * The queue only ever changes by server decree.
 *
 * It is not derived from counting `user` events, because the two disagree
 * constantly: a message typed mid-turn is usually handed straight to the
 * running turn and never queued at all, while a refused steer, an interrupt, a
 * drop and a drain each move the queue differently. The server sends the list
 * and that list wins.
 */
function queueAfter(current: string[], event: AgentEvent): string[] {
  if (event.kind === "queue") {
    return (event.payload.messages as string[] | undefined) ?? current
  }
  // A turn starting means the queue went out with it.
  if (event.kind === "status" && event.payload.status === "starting") return []
  return current
}

/**
 * Fold a delta in, once.
 *
 * The `delta_seq` guard is not defensive programming — it fixes a real defect.
 * phoenix.js skips the leave push when a channel has not finished joining (it
 * fakes a local "ok"), so a mount-then-immediately-remount — which React
 * StrictMode does on every mount — leaves a channel alive on the server, still
 * subscribed and still pushing. Measured: every delta arrived exactly twice
 * while `socket.channels` held only one channel.
 *
 * Events survived that because `seq` already deduplicated them. Deltas append,
 * so a double produced text interleaved with itself ("AAWS Lambda WebWS
 * Lambda Web Functions"), and a duplicate arriving *after* the authoritative
 * event had cleared the placeholder rebuilt it as a stray empty block.
 */
export function applyDelta(t: Transcript, delta: AgentDelta): Transcript {
  if (delta.delta_seq !== undefined && delta.delta_seq <= t.lastDeltaSeq) return t
  t = { ...t, lastDeltaSeq: delta.delta_seq ?? t.lastDeltaSeq }

  if (delta.type === "block_end") return t

  // Tool output goes into its own bucket, appended onto the card the
  // `tool_use` event already created. Only Codex streams this; a ten-minute
  // build is why it exists.
  if (delta.type === "tool_output") {
    const existing = t.toolStreams.find((s) => s.blockId === delta.block_id)
    const chunk = delta.chunk ?? ""
    return {
      ...t,
      toolStreams: existing
        ? t.toolStreams.map((s) =>
            s.blockId === delta.block_id ? { ...s, text: s.text + chunk } : s,
          )
        : [...t.toolStreams, { blockId: delta.block_id, text: chunk }],
    }
  }

  const existing = t.streaming.find((b) => b.blockId === delta.block_id)

  if (!existing) {
    const block = newBlock(delta)
    return block ? { ...t, streaming: [...t.streaming, block] } : t
  }

  if (delta.type !== "text" && delta.type !== "thinking") return t

  return {
    ...t,
    streaming: t.streaming.map((b) =>
      b.blockId === delta.block_id
        ? { ...b, text: b.text + (delta.chunk ?? "") }
        : b,
    ),
  }
}

function newBlock(delta: AgentDelta): StreamingBlock | null {
  if (delta.type === "tool_use_start") {
    return {
      blockId: delta.block_id,
      kind: "tool_use",
      text: "",
      name: delta.name,
    }
  }

  const kind =
    delta.type === "thinking" || delta.block_type === "thinking"
      ? "thinking"
      : "text"

  // A chunk can arrive before its `block_start` (or without one at all), so a
  // block is created on first sight rather than only on block_start.
  if (delta.type === "block_start") {
    return { blockId: delta.block_id, kind, text: "" }
  }
  if (delta.type === "text" || delta.type === "thinking") {
    return { blockId: delta.block_id, kind, text: delta.chunk ?? "" }
  }
  return null
}

export function addPending(t: Transcript, pending: PendingMessage): Transcript {
  return { ...t, pending: [...t.pending, pending] }
}

/** Whether a turn is in flight — which is not the same as "not idle". */
export function isBusy(t: Transcript): boolean {
  return t.status === "starting" || t.status === "running"
}

// ── Timeline ───────────────────────────────────────────────────────────────

export type ToolResult = { ok: boolean; output: string }

// A scheduled prompt, as `Loom.Cron.list/0` reports it. Times are ISO 8601,
// UTC; `cron` is matched in UTC too.
export type CronJob = {
  id: string
  name: string
  cron: string
  target: string
  target_title: string | null
  prompt: string
  next_at: string | null
  last_run_at: string | null
  last_error: string | null
}

export type TimelineItem =
  | {
      key: string
      kind: "user"
      text: string
      // Shown as chips. The paths went to the model in the message it
      // received, not in `text` — see `Loom.Agent.Files`.
      files: AgentFile[]
      origin?: string
      // When the server took it, ms since the epoch. Absent while it is still
      // our own optimistic bubble.
      at?: number
      queued: boolean
      pending: boolean
    }
  | { key: string; kind: "assistant"; text: string; streaming: boolean }
  | { key: string; kind: "thinking"; text: string; streaming: boolean }
  | {
      key: string
      kind: "tool"
      name: string
      input: Record<string, unknown>
      // Output streaming out while it runs. Replaced by `result` when the tool
      // finishes — the stream is for liveness, the result is the truth.
      streamed: string
      result: ToolResult | null
    }
  | { key: string; kind: "question"; question: string; options: string[] }
  // A finished stretch of tool calls folded into one card; see `foldFinished`.
  // `steps` are the tool cards and any thinking with words in it, in order.
  | { key: string; kind: "tools"; steps: TimelineItem[]; tools: number; failed: number }
  // What a turn left in the output directory, offered for download. `more`
  // counts files past the server's cap.
  | { key: string; kind: "outputs"; files: OutputFile[]; more: number }
  | { key: string; kind: "notice"; text: string }
  | { key: string; kind: "retry"; text: string }
  // The answer to `/cron`: every scheduled job, as of when it was typed.
  | { key: string; kind: "cron"; jobs: CronJob[] }
  | { key: string; kind: "error"; text: string }
  | {
      key: string
      kind: "turn"
      at: number
      contextTokens: number
      contextWindow: number | null
    }

/**
 * Flatten the transcript into what gets rendered.
 *
 * Events come first in `seq` order, then the still-streaming placeholders, then
 * our own unacknowledged messages. That order is right because the server emits
 * a response's events only after the whole response is assembled — so every
 * delta currently in flight belongs after everything already evented.
 */
export function buildTimeline(t: Transcript): TimelineItem[] {
  const items: TimelineItem[] = []
  // tool_use id → index in `items`, so its result can be attached to the card
  // rather than floating as a separate bubble.
  const toolIndex = new Map<string, number>()

  for (const event of t.events) {
    const p = event.payload
    const key = `e${event.seq}`

    switch (event.kind) {
      case "user":
        items.push({
          key,
          kind: "user",
          text: String(p.text ?? ""),
          files: (p.files as AgentFile[] | undefined) ?? [],
          origin: p.origin as string | undefined,
          at: event.at,
          queued: p.status === "queued",
          pending: false,
        })
        break

      case "assistant_text":
        items.push({
          key,
          kind: "assistant",
          text: String(p.text ?? ""),
          streaming: false,
        })
        break

      case "thinking":
        items.push({
          key,
          kind: "thinking",
          text: String(p.text ?? ""),
          streaming: false,
        })
        break

      case "tool_use":
        toolIndex.set(String(p.id), items.length)
        items.push({
          key,
          kind: "tool",
          name: String(p.name ?? "tool"),
          input: (p.input as Record<string, unknown>) ?? {},
          streamed: streamFor(t, String(p.block_id ?? p.id)),
          result: null,
        })
        break

      case "tool_result": {
        const at = toolIndex.get(String(p.id))
        const result: ToolResult = {
          ok: p.status !== "error",
          output: String(p.output ?? ""),
        }
        if (at !== undefined) {
          const card = items[at]
          if (card.kind === "tool") items[at] = { ...card, result }
        } else {
          // The matching tool_use fell outside the retained transcript.
          items.push({
            key,
            kind: "tool",
            name: String(p.name ?? "tool"),
            input: {},
            streamed: "",
            result,
          })
        }
        break
      }

      case "question":
        items.push({
          key,
          kind: "question",
          question: String(p.question ?? ""),
          options: (p.options as string[]) ?? [],
        })
        break

      case "error":
        items.push({ key, kind: "error", text: String(p.message ?? "error") })
        break

      case "api_retry": {
        // The API refused a request and the backend is about to try again.
        // One line for the whole run of them, showing the latest: ten
        // attempts would otherwise be ten lines saying the same thing.
        const status = p.status ? `${p.status}${p.error ? ` ${p.error}` : ""}` : String(p.error ?? "error")
        const delay = Number(p.delay_ms ?? 0)
        const text =
          `API ${status}, retrying ${p.attempt}/${p.max_retries}` +
          (delay >= 1000 ? ` in ${Math.round(delay / 1000)}s` : "")
        const last = items[items.length - 1]
        if (last?.kind === "retry") items[items.length - 1] = { ...last, text }
        else items.push({ key, kind: "retry", text })
        break
      }

      case "compacted": {
        // The backend compacted its own context. Worth one line so a jump in
        // the token count has an explanation. Claude Code reports the sizes;
        // Codex does not, and its count catches up on the next turn.
        const pre = Number(p.pre_tokens)
        const post = Number(p.post_tokens)
        let text = p.trigger === "auto" ? "context compacted automatically" : "context compacted"
        if (pre > 0 && post > 0) text += `: ${kTokens(pre)} → ${kTokens(post)}`
        items.push({ key, kind: "notice", text })
        break
      }

      case "reload_requested":
        // `/reload` is answered by loom, not the model; say what it set off.
        items.push({
          key,
          kind: "notice",
          text: "reload: Claude Code restarts on its next turn, Codex once no Codex turn is running",
        })
        break

      case "cron_jobs":
        items.push({ key, kind: "cron", jobs: (p.jobs as CronJob[] | undefined) ?? [] })
        break

      case "output_files":
        items.push({
          key,
          kind: "outputs",
          files: (p.files as OutputFile[] | undefined) ?? [],
          more: Number(p.more ?? 0),
        })
        break

      case "renamed":
        break

      case "queue":
        // Queue depth is header state, not a transcript entry.
        break

      case "turn_done":
        items.push({
          key,
          kind: "turn",
          at: event.at,
          contextTokens: Number(p.context_tokens ?? 0),
          contextWindow: (p.context_window as number | null) ?? null,
        })
        break

      case "status": {
        // Running states drive the header indicator, not the transcript. Only
        // a stop is worth a line, because it explains why the output ends
        // mid-thought — and the server says why it stopped.
        if (p.status === "interrupted") {
          items.push({
            key,
            kind: "notice",
            text: String(p.message ?? "interrupted"),
          })
        }
        break
      }

      // `usage` is a header number, not a transcript entry.
      default:
        break
    }
  }

  for (const block of t.streaming) {
    if (block.kind === "tool_use") {
      items.push({
        key: `s${block.blockId}`,
        kind: "tool",
        name: block.name ?? "tool",
        input: {},
        streamed: streamFor(t, block.blockId),
        result: null,
      })
    } else {
      items.push({
        key: `s${block.blockId}`,
        kind: block.kind === "thinking" ? "thinking" : "assistant",
        text: block.text,
        streaming: true,
      })
    }
  }

  for (const p of t.pending) {
    items.push({
      key: `p${p.clientMsgId}`,
      kind: "user",
      text: p.text,
      files: p.files,
      queued: false,
      pending: true,
    })
  }

  return items
}

/**
 * Fold every finished stretch of tool calls into one card.
 *
 * While a turn runs, each call is its own card, because watching them land is
 * how you know it is not stuck. Once the turn is over they are history: ten
 * cards of `cat` and `grep` push the answer off the screen, and the answer is
 * what you came back for. So a stretch of consecutive tools and thinking —
 * between the user's message, the replies, the turn's end — becomes one
 * "used N tools" card that opens to the same cards as before. Stretches, not
 * whole turns: a reply written between two batches of calls stays where it
 * was written.
 *
 * Thinking with no words in it ("thought for a moment") says nothing once the
 * turn is over and is dropped; thinking that has words goes inside the card.
 *
 * "Finished" is everything up to the last turn ending (its context line, an
 * error, a stop notice) while the agent is busy, and everything when it is not.
 */
export function foldFinished(items: TimelineItem[], busy: boolean): TimelineItem[] {
  let live = items.length
  if (busy) {
    live = 0
    items.forEach((item, i) => {
      if (item.kind === "turn" || item.kind === "error" || item.kind === "notice") live = i + 1
    })
  }

  const out: TimelineItem[] = []
  let run: TimelineItem[] = []

  const flush = () => {
    const tools = run.filter((s) => s.kind === "tool")
    if (tools.length > 0) {
      out.push({
        key: `g${run[0].key}`,
        kind: "tools",
        steps: run,
        tools: tools.length,
        failed: tools.filter((s) => s.kind === "tool" && s.result?.ok === false).length,
      })
    } else {
      // Thinking on its own, with no tools to sit under, stays as it was.
      out.push(...run)
    }
    run = []
  }

  items.slice(0, live).forEach((item) => {
    if (item.kind === "tool") {
      run.push(item)
    } else if (item.kind === "thinking") {
      if (item.text.trim() !== "") run.push(item)
    } else {
      flush()
      out.push(item)
    }
  })
  flush()

  return out.concat(items.slice(live))
}

function streamFor(t: Transcript, blockId: string): string {
  return t.toolStreams.find((s) => s.blockId === blockId)?.text ?? ""
}

// 15723 → "16K", 1257 → "1.3K": one decimal only where it carries anything.
function kTokens(n: number): string {
  if (n < 1000) return String(n)
  return n < 10_000 ? `${(n / 1000).toFixed(1)}K` : `${Math.round(n / 1000)}K`
}

export function newClientMsgId(): string {
  return "c_" + Math.random().toString(36).slice(2, 10)
}
