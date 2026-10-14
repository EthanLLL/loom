import { useEffect, useLayoutEffect, useRef, useState } from "react"
import { buildTimeline, isBusy, type TimelineItem } from "./agent"
import { useAgent } from "./useAgent"
import type { AgentInfo } from "./api"
import "./Chat.css"

type Props = {
  session: AgentInfo
  sidebarOpen: boolean
  onToggleSidebar: () => void
  terminalOpen: boolean
  terminalCount: number
  onToggleTerminal: () => void
}

export function Chat({
  session,
  sidebarOpen,
  onToggleSidebar,
  terminalOpen,
  terminalCount,
  onToggleTerminal,
}: Props) {
  const { transcript, joinError, submit, interrupt, dropQueued, rename } =
    useAgent(session.id)
  const items = buildTimeline(transcript)
  const busy = isBusy(transcript)

  return (
    <div className="chat">
      <header className="chat-header">
        {!sidebarOpen && (
          <button
            className="icon-btn"
            onClick={onToggleSidebar}
            title="Show sidebar"
          >
            ☰
          </button>
        )}

        <Title
          title={session.title ?? session.id}
          backend={session.backend_label}
          onRename={rename}
        />

        <div className="chat-meta">
          <StatusPill
            status={transcript.status}
            queued={transcript.queue.length}
          />
          {transcript.contextTokens > 0 && (
            <span
              className={"chip" + contextPressure(transcript)}
              title="How big the conversation is now, against the model's window"
            >
              {formatTokens(transcript.contextTokens)}
              {transcript.contextWindow
                ? ` / ${formatTokens(transcript.contextWindow)}`
                : ""}
            </span>
          )}
          <button
            className={"chip button" + (terminalOpen ? " on" : "")}
            onClick={onToggleTerminal}
            title="Toggle terminals (they open in your home directory)"
          >
            terminal{terminalCount > 1 ? ` ${terminalCount}` : ""}
          </button>
        </div>
      </header>

      {joinError && <div className="chat-banner">{joinError}</div>}

      <Timeline
        items={items}
        truncatedBefore={transcript.truncatedBefore}
        onAnswer={submit}
      />

      {transcript.queue.length > 0 && (
        <QueuePanel
          messages={transcript.queue}
          interrupted={transcript.status === "interrupted"}
          onDrop={dropQueued}
        />
      )}

      <Composer
        busy={busy}
        interrupted={transcript.status === "interrupted"}
        onSubmit={submit}
        onInterrupt={interrupt}
      />
    </div>
  )
}

// ── Timeline ───────────────────────────────────────────────────────────────

function Timeline({
  items,
  truncatedBefore,
  onAnswer,
}: {
  items: TimelineItem[]
  truncatedBefore: number | null
  onAnswer: (text: string) => void
}) {
  const ref = useRef<HTMLDivElement>(null)
  const pinnedRef = useRef(true)

  // Only follow the output when the user is already at the bottom; scrolling up
  // to read something while the agent streams must not yank them back down.
  const onScroll = () => {
    const el = ref.current
    if (!el) return
    pinnedRef.current =
      el.scrollHeight - el.scrollTop - el.clientHeight < 80
  }

  useLayoutEffect(() => {
    const el = ref.current
    if (el && pinnedRef.current) el.scrollTop = el.scrollHeight
  }, [items])

  return (
    <div className="timeline" ref={ref} onScroll={onScroll}>
      {truncatedBefore ? (
        <div className="notice">
          earlier messages are no longer kept in memory (up to #
          {truncatedBefore})
        </div>
      ) : null}

      {items.length === 0 && (
        <div className="empty">Send a message to start.</div>
      )}

      {items.map((item) => (
        <Item key={item.key} item={item} onAnswer={onAnswer} />
      ))}
    </div>
  )
}

function Item({
  item,
  onAnswer,
}: {
  item: TimelineItem
  onAnswer: (text: string) => void
}) {
  switch (item.kind) {
    case "user":
      return (
        <div className={"bubble user" + (item.pending ? " pending" : "")}>
          <Rich text={item.text} />
          {item.queued && <span className="tag">queued</span>}
          {item.origin === "phone" && <span className="tag">phone</span>}
        </div>
      )

    case "assistant":
      return (
        <div className={"bubble assistant" + (item.streaming ? " live" : "")}>
          <Rich text={item.text} />
        </div>
      )

    case "thinking":
      // Opus returns thinking blocks with empty text under the default
      // display, so the fallback is the normal case rather than an edge case.
      return (
        <div className="thinking">{item.text.trim() || "thought for a moment"}</div>
      )

    case "tool":
      return <ToolCard item={item} />

    case "question":
      return (
        <div className="question">
          <Rich text={item.question} />
          {item.options.length > 0 && (
            <div className="options">
              {/* The model supplies options precisely so the answer is one
                  click; typing them back out would waste that. */}
              {item.options.map((o) => (
                <button className="option" key={o} onClick={() => onAnswer(o)}>
                  {o}
                </button>
              ))}
            </div>
          )}
        </div>
      )

    case "turn":
      return <TurnLine item={item} />

    case "error":
      return <div className="error">{item.text}</div>

    case "notice":
      return <div className="notice">{item.text}</div>
  }
}

/**
 * The session name, editable in place.
 *
 * Renaming is loom-local — the title is a sidebar label, not conversation
 * state — so it never goes to the backend and needs no confirmation.
 */
function Title({
  title,
  backend,
  onRename,
}: {
  title: string
  backend: string
  onRename: (title: string) => void
}) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(title)

  const commit = () => {
    const value = draft.trim()
    if (value !== "" && value !== title) onRename(value)
    setEditing(false)
  }

  return (
    <div className="chat-title">
      {editing ? (
        <input
          className="chat-name-input"
          value={draft}
          autoFocus
          onChange={(e) => setDraft(e.target.value)}
          onBlur={commit}
          onKeyDown={(e) => {
            if (e.key === "Enter") commit()
            if (e.key === "Escape") {
              setDraft(title)
              setEditing(false)
            }
          }}
        />
      ) : (
        <span
          className="chat-name"
          title="Double-click to rename"
          onDoubleClick={() => {
            setDraft(title)
            setEditing(true)
          }}
        >
          {title}
        </span>
      )}
      <span className="chat-backend">{backend}</span>
    </div>
  )
}

/**
 * Messages waiting for the current turn, or parked by an interrupt.
 *
 * Showing them matters most in the interrupted case: they were written for a
 * trajectory that no longer exists, so the user needs to see what is about to
 * be sent and be able to drop a line that no longer applies.
 */
function QueuePanel({
  messages,
  interrupted,
  onDrop,
}: {
  messages: string[]
  interrupted: boolean
  onDrop: (index: number) => void
}) {
  return (
    <div className={"queue-panel" + (interrupted ? " parked" : "")}>
      <div className="queue-head">
        {/* Only reachable when the backend refused to take the message into the
            running turn, or when the session was stopped. A message typed
            mid-turn normally goes straight in. */}
        {interrupted
          ? `${messages.length} message${messages.length > 1 ? "s" : ""} parked — they go out with your next one`
          : `${messages.length} waiting — the turn would not take it`}
      </div>
      {messages.map((text, i) => (
        <div className="queue-item" key={i}>
          <span className="queue-text">{text}</span>
          <button
            className="queue-drop"
            title="Discard this message"
            onClick={() => onDrop(i)}
          >
            ×
          </button>
        </div>
      ))}
    </div>
  )
}

function ToolCard({
  item,
}: {
  item: Extract<TimelineItem, { kind: "tool" }>
}) {
  const [open, setOpen] = useState(false)
  const summary = toolSummary(item.name, item.input)
  const result = item.result

  // While it runs, show whatever has streamed out; once it finishes, the
  // result replaces it. The stream is for liveness and may be partial — Codex
  // coalesces chunks — so it is never the thing we keep.
  const output = result ? result.output : item.streamed
  const live = !result && item.streamed !== ""

  return (
    <div className={"tool" + (result && !result.ok ? " failed" : "")}>
      <div className="tool-head" onClick={() => setOpen((v) => !v)}>
        <span className="tool-name">{item.name}</span>
        <span className="tool-summary">{summary}</span>
        <span className="tool-state">
          {result ? (result.ok ? "✓" : "✕") : "…"}
        </span>
      </div>

      {open && Object.keys(item.input).length > 0 && (
        <pre className="tool-input">{formatInput(item.input)}</pre>
      )}

      {output.trim() !== "" && (
        <pre
          className={
            "tool-output" + (open ? " full" : "") + (live ? " live" : "")
          }
        >
          {output}
        </pre>
      )}
    </div>
  )
}

// A quiet end-of-turn marker. Worth a line because it is where the context and
// cost numbers in the header came from.
function TurnLine({ item }: { item: Extract<TimelineItem, { kind: "turn" }> }) {
  const parts: string[] = []
  if (item.contextTokens > 0) {
    parts.push(
      item.contextWindow
        ? `${formatTokens(item.contextTokens)} / ${formatTokens(item.contextWindow)}`
        : `${formatTokens(item.contextTokens)} ctx`,
    )
  }
  if (parts.length === 0) return null
  return <div className="turn-line">{parts.join(" · ")}</div>
}

function StatusPill({ status, queued }: { status: string; queued: number }) {
  // `starting` is the backend booting — seconds for Claude Code, which spawns
  // a process per turn. Saying so beats looking hung.
  const label = STATUS_LABELS[status] ?? status
  return (
    <span className={"chip status " + status}>
      {label}
      {queued > 0 ? ` · ${queued} queued` : ""}
    </span>
  )
}

const STATUS_LABELS: Record<string, string> = {
  idle: "idle",
  starting: "starting…",
  running: "working",
  interrupted: "stopped",
}

// ── Composer ───────────────────────────────────────────────────────────────

function Composer({
  busy,
  interrupted,
  onSubmit,
  onInterrupt,
}: {
  busy: boolean
  interrupted: boolean
  onSubmit: (text: string) => void
  onInterrupt: () => void
}) {
  const [text, setText] = useState("")
  const ref = useRef<HTMLTextAreaElement>(null)
  // True between compositionstart and compositionend. Needed in addition to
  // `isComposing` because the two disagree across browsers — see below.
  const composingRef = useRef(false)

  // Grow with the content instead of scrolling inside a two-line box.
  useEffect(() => {
    const el = ref.current
    if (!el) return
    el.style.height = "auto"
    el.style.height = Math.min(el.scrollHeight, 220) + "px"
  }, [text])

  const send = () => {
    const value = text.trim()
    if (value === "") return
    onSubmit(value)
    setText("")
  }

  return (
    <div className="composer">
      <textarea
        ref={ref}
        className="composer-input"
        value={text}
        rows={1}
        placeholder={
          busy
            ? "Say something — it reaches the agent mid-turn…"
            : interrupted
              ? "Stopped. Type to continue — parked messages go with this one."
              : "Message the agent…"
        }
        onChange={(e) => setText(e.target.value)}
        onCompositionStart={() => {
          composingRef.current = true
        }}
        onCompositionEnd={() => {
          composingRef.current = false
        }}
        onKeyDown={(e) => {
          if (e.key !== "Enter" || e.shiftKey) return

          // An IME uses Enter to commit the candidate, and that keystroke must
          // not also send the message. Both guards are needed because the
          // browsers disagree about ordering:
          //
          //   Chrome  — the committing keydown has isComposing === true.
          //   Safari  — compositionend fires *after* that keydown, so
          //             isComposing is already false; the ref is still true.
          //
          // Either way the commit is swallowed, and the next Enter (with no
          // composition in progress) sends.
          if (e.nativeEvent.isComposing || composingRef.current) return

          e.preventDefault()
          send()
        }}
      />
      {busy && (
        <button className="composer-btn stop" onClick={onInterrupt}>
          stop
        </button>
      )}
      <button
        className="composer-btn send"
        onClick={send}
        disabled={text.trim() === ""}
      >
        {interrupted ? "continue" : "send"}
      </button>
    </div>
  )
}

// ── Text rendering ─────────────────────────────────────────────────────────

/**
 * Just enough markdown to make agent output readable: fenced blocks and inline
 * code. Deliberately not a markdown library — the model is told to be concise
 * and point at paths, so headings and tables are rare and a full parser would
 * be more surface than it is worth.
 */
function Rich({ text }: { text: string }) {
  const parts = text.split("```")

  return (
    <>
      {parts.map((part, i) =>
        i % 2 === 1 ? (
          <pre className="code" key={i}>
            {part.replace(/^[\w+-]*\n/, "")}
          </pre>
        ) : (
          <span className="prose" key={i}>
            {inlineCode(part)}
          </span>
        ),
      )}
    </>
  )
}

function inlineCode(text: string) {
  return text.split("`").map((piece, i) =>
    i % 2 === 1 ? (
      <code key={i}>{piece}</code>
    ) : (
      <span key={i}>{piece}</span>
    ),
  )
}

// ── Formatting ─────────────────────────────────────────────────────────────

function toolSummary(name: string, input: Record<string, unknown>): string {
  const str = (key: string) => String(input[key] ?? "")

  switch (name) {
    // Claude Code
    case "Bash":
      return str("command")
    case "Read":
    case "Write":
    case "Edit":
    case "NotebookEdit":
      return str("file_path")
    case "Glob":
      return str("pattern")
    case "Grep":
      return str("pattern") + (input.path ? ` in ${str("path")}` : "")
    case "WebFetch":
      return str("url")
    case "Task":
      return str("description")
    case "Skill":
      return str("skill")

    // Codex
    case "shell":
      return (input.cwd ? `${str("cwd")} ` : "") + str("command")
    case "apply_patch":
      return patchFiles(str("patch")).join(", ") || changedFiles(input) || "patch"
    case "web_search":
      return str("query")

    default:
      return Object.keys(input).length > 0 ? formatInput(input) : ""
  }
}

// Codex reports a patch as structured changes rather than an envelope.
function changedFiles(input: Record<string, unknown>): string {
  const changes = input.changes
  if (!Array.isArray(changes)) return ""
  return changes
    .map((c) =>
      c && typeof c === "object" ? String((c as Record<string, unknown>).path ?? "") : "",
    )
    .filter((p) => p !== "")
    .join(", ")
}

// The envelope names every file it touches on its own header lines, which is a
// far better one-line summary than the first 80 characters of a diff.
function patchFiles(patch: string): string[] {
  const files: string[] = []
  for (const line of patch.split("\n")) {
    const m = /^\*\*\* (?:Add|Update|Delete) File: (.+)$/.exec(line.trim())
    if (m) files.push(m[1])
  }
  return files
}

function formatInput(input: Record<string, unknown>): string {
  const entries = Object.entries(input)
  if (entries.length === 1 && typeof entries[0][1] === "string") {
    return entries[0][1] as string
  }
  return JSON.stringify(input, null, 2)
}

function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(n >= 10_000_000 ? 0 : 1)}M`
  if (n >= 1000) return `${Math.round(n / 1000)}K`
  return String(n)
}

// The backends compact themselves, so this is information rather than a
// warning — but seeing it climb is how you know a compaction is coming.
function contextPressure(t: { contextTokens: number; contextWindow: number | null }): string {
  if (!t.contextWindow) return ""
  const used = t.contextTokens / t.contextWindow
  if (used >= 0.9) return " hot"
  if (used >= 0.7) return " warm"
  return ""
}
