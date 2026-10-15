import { useLayoutEffect, useRef, useState } from "react"
import { buildTimeline, isBusy, type TimelineItem } from "./agent"
import { Markdown } from "./markdown"
import { useAgent } from "./useAgent"
import {
  useAttachments,
  useFileDrop,
  type Attachment,
  type Attachments,
} from "./useAttachments"
import type { AgentFile, AgentInfo } from "./api"
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

  const attachments = useAttachments(session.id)
  // Dropping is accepted anywhere in the conversation, not just on the
  // composer: by the time you have dragged a screenshot this far, aiming at a
  // 40-pixel target is the last thing you want to do.
  const drop = useFileDrop(attachments.add)

  const send = (text: string) => {
    submit(text, attachments.ready)
    attachments.clear()
  }

  return (
    <div
      className={"chat" + (drop.dragging ? " dragging" : "")}
      {...drop.handlers}
    >
      {drop.dragging && (
        <div className="drop-note">drop to attach to this conversation</div>
      )}

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
              {/* The window is fixed per model; on a phone the header has no
                  room for a number that never changes. */}
              {transcript.contextWindow ? (
                <span className="wide-only">
                  {` / ${formatTokens(transcript.contextWindow)}`}
                </span>
              ) : null}
            </span>
          )}
          <button
            className={"chip button" + (terminalOpen ? " on" : "")}
            onClick={onToggleTerminal}
            title="Toggle terminals (they open in your home directory)"
          >
            <span className="wide-only">terminal</span>
            <span className="narrow-only">&gt;_</span>
            {terminalCount > 1 ? ` ${terminalCount}` : ""}
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
        attachments={attachments}
        onSubmit={send}
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
      {/* The scroll container is the outer element and the measure is this
          one, so prose, tool cards and turn lines all share a single column
          width — a card spanning the window while the text beside it stopped
          half way across read as two different layouts. */}
      <div className="timeline-inner">
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
          {item.text.trim() !== "" && <Rich text={item.text} />}
          {item.files.length > 0 && <SentFiles files={item.files} />}
          {item.queued && <span className="tag">queued</span>}
          {item.origin === "phone" && <span className="tag">phone</span>}
        </div>
      )

    case "assistant":
      // The only place markdown is rendered. Tool output and the user's own
      // words are shown verbatim — see `markdown.tsx`.
      return (
        <div className={"bubble assistant" + (item.streaming ? " live" : "")}>
          <Markdown text={item.text} />
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

/**
 * The attachments that went out with a message.
 *
 * Names, not thumbnails: showing the image would mean fetching it back through
 * an authenticated request and is not what the message is about — the agent
 * reads the file from the path, and the chip is there to say which file.
 */
function SentFiles({ files }: { files: AgentFile[] }) {
  return (
    <div className="files">
      {files.map((file) => (
        <span className="file" key={file.path} title={file.path}>
          {fileIcon(file.content_type)} {file.name}
          <span className="file-size">{formatBytes(file.size)}</span>
        </span>
      ))}
    </div>
  )
}

function fileIcon(contentType: string): string {
  if (contentType.startsWith("image/")) return "🖼"
  if (contentType.startsWith("audio/")) return "🔊"
  if (contentType.startsWith("video/")) return "🎞"
  return "📄"
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
  // `starting` is the backend booting — seconds for a cold Claude Code
  // process. Saying so beats looking hung.
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
  attachments,
  onSubmit,
  onInterrupt,
}: {
  busy: boolean
  interrupted: boolean
  attachments: Attachments
  onSubmit: (text: string) => void
  onInterrupt: () => void
}) {
  const [text, setText] = useState("")
  const ref = useRef<HTMLTextAreaElement>(null)
  const picker = useRef<HTMLInputElement>(null)
  // True between compositionstart and compositionend. Needed in addition to
  // `isComposing` because the two disagree across browsers — see below.
  const composingRef = useRef(false)

  // One line with the buttons beside it until the text needs more; then the
  // text gets the full width and the buttons drop to a row underneath.
  const [multiline, setMultiline] = useState(false)
  // How long the text was when it first wrapped. Going multiline widens the
  // box, so the same text may fit on one line again — leaving at that point
  // would flip straight back. The font is monospace, so length tracks width.
  const wrappedAt = useRef(0)

  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    const style = getComputedStyle(el)
    const line = parseFloat(style.lineHeight)
    const padding = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom)

    if (text === "") {
      // The placeholder can wrap too, and is not worth a second line.
      wrappedAt.current = 0
      setMultiline(false)
      el.style.height = ""
      return
    }

    el.style.height = "auto"
    const content = el.scrollHeight - padding

    if (!multiline && (text.includes("\n") || content > line * 1.5)) {
      wrappedAt.current = text.length
      setMultiline(true)
      return // measured again in the wider layout
    }
    if (multiline && !text.includes("\n") && text.length < wrappedAt.current) {
      setMultiline(false)
      return
    }

    // Grow to six lines, then scroll inside.
    el.style.height = Math.min(content, line * MAX_LINES) + padding + "px"
  }, [text, multiline])

  // An attachment on its own is a message: dragging in a screenshot and
  // pressing send, with nothing typed, is a normal way to ask about it.
  const sendable =
    (text.trim() !== "" || attachments.ready.length > 0) && !attachments.uploading

  const send = () => {
    if (!sendable) return
    onSubmit(text.trim())
    setText("")
  }

  return (
    <div className="composer">
      {attachments.items.length > 0 && (
        <div className="tray">
          {attachments.items.map((item) => (
            <AttachmentChip
              key={item.key}
              item={item}
              onRemove={() => attachments.remove(item.key)}
            />
          ))}
        </div>
      )}

      <div className={"composer-box" + (multiline ? " multiline" : "")}>
        <input
          ref={picker}
          className="composer-file"
          type="file"
          multiple
          onChange={(e) => {
            attachments.add(Array.from(e.target.files ?? []))
            // Reset, or picking the same file twice in a row does nothing.
            e.target.value = ""
          }}
        />
        <button
          className="composer-btn attach"
          title="Attach files — or drop them anywhere in the conversation"
          onClick={() => picker.current?.click()}
        >
          <PlusIcon />
        </button>

        <textarea
          ref={ref}
          className="composer-input"
          value={text}
          rows={1}
          placeholder={
            busy
              ? "Steer the agent mid-turn…"
              : interrupted
                ? "Stopped — type to continue"
                : "Message the agent…"
          }
          onChange={(e) => setText(e.target.value)}
          // A pasted screenshot is the commonest attachment there is, and it
          // never exists as a file on disk to pick.
          onPaste={(e) => {
            const files = Array.from(e.clipboardData.files)
            if (files.length === 0) return
            e.preventDefault()
            attachments.add(files)
          }}
          onCompositionStart={() => {
            composingRef.current = true
          }}
          onCompositionEnd={() => {
            composingRef.current = false
          }}
          onKeyDown={(e) => {
            if (e.key !== "Enter" || e.shiftKey) return

            // An IME uses Enter to commit the candidate, and that keystroke
            // must not also send the message. Both guards are needed because
            // the browsers disagree about ordering:
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

        <div className="composer-actions">
          {busy && (
            <button
              className="composer-btn stop"
              onClick={onInterrupt}
              title="Stop the turn"
            >
              <StopIcon />
            </button>
          )}
          {/* While the agent works, an empty box has nothing to send and the
              stop button is the one that matters. */}
          {!(busy && !sendable) && (
            <button
              className="composer-btn send"
              onClick={send}
              disabled={!sendable}
              title={
                attachments.uploading
                  ? "Uploading…"
                  : interrupted
                    ? "Continue"
                    : busy
                      ? "Send — it reaches the agent mid-turn"
                      : "Send"
              }
            >
              <SendIcon />
            </button>
          )}
        </div>
      </div>
    </div>
  )
}

// Past this the box scrolls instead of eating the conversation.
const MAX_LINES = 6

// Inline rather than an icon font: three glyphs do not justify a dependency,
// and the Nerd Font's versions sit on the text baseline instead of centred.
function PlusIcon() {
  return (
    <svg viewBox="0 0 24 24" width="1.25em" height="1.25em" aria-hidden>
      <path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
    </svg>
  )
}

function SendIcon() {
  return (
    <svg viewBox="0 0 24 24" width="1.25em" height="1.25em" aria-hidden>
      <path
        d="M12 19V5M6 11l6-6 6 6"
        fill="none"
        stroke="currentColor"
        strokeWidth="2.2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function StopIcon() {
  return (
    <svg viewBox="0 0 24 24" width="1em" height="1em" aria-hidden>
      <rect x="6" y="6" width="12" height="12" rx="2" fill="currentColor" />
    </svg>
  )
}

/** One pending attachment: uploading, failed, or ready to go. */
function AttachmentChip({
  item,
  onRemove,
}: {
  item: Attachment
  onRemove: () => void
}) {
  const state = item.error ? " failed" : item.file ? "" : " uploading"

  return (
    <span className={"tray-item" + state} title={item.error ?? item.file?.path}>
      <span className="tray-name">{item.name}</span>
      <span className="tray-note">
        {item.error ?? (item.file ? formatBytes(item.size) : "…")}
      </span>
      <button className="tray-drop" title="Remove" onClick={onRemove}>
        ×
      </button>
    </span>
  )
}

// ── Text rendering ─────────────────────────────────────────────────────────

/**
 * Fenced blocks and inline code, nothing else.
 *
 * Used for the *user's* messages and for a question's prompt — text that was
 * typed by a person, where turning a `*` into emphasis would be rewriting what
 * they wrote. Assistant messages go through `Markdown` instead.
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

function formatBytes(n: number): string {
  if (n >= 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`
  if (n >= 1024) return `${Math.round(n / 1024)} KB`
  return `${n} B`
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
