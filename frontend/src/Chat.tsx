import {
  createContext,
  useContext,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react"
import { buildTimeline, foldFinished, isBusy, type CronJob, type TimelineItem } from "./agent"
import { itemForOutput, itemForPath, type CanvasItem } from "./canvasItems"
import { Markdown, OutputLink } from "./markdown"
import { useAgent } from "./useAgent"
import {
  useAttachments,
  useFileDrop,
  type Attachment,
  type Attachments,
} from "./useAttachments"
import {
  attachmentUrl,
  blobUrl,
  downloadAgentOutput,
  downloadAgentZip,
  outputUrl,
  type AgentFile,
  type AgentInfo,
  type OutputFile,
} from "./api"
import "./Chat.css"

type Props = {
  session: AgentInfo
  sidebarOpen: boolean
  onToggleSidebar: () => void
  terminalOpen: boolean
  terminalCount: number
  onToggleTerminal: () => void
  canvasOpen: boolean
  onToggleCanvas: () => void
  onOpenCanvas: (item: CanvasItem) => void
}

// How a card or link deep in the transcript opens something in the canvas.
const OpenCanvas = createContext<(item: CanvasItem) => void>(() => {})

export function Chat({
  session,
  sidebarOpen,
  onToggleSidebar,
  terminalOpen,
  terminalCount,
  onToggleTerminal,
  canvasOpen,
  onToggleCanvas,
  onOpenCanvas,
}: Props) {
  const { transcript, joinError, submit, interrupt, dropQueued, rename } = useAgent(
    session.id,
    (event) => {
      // A turn that just built a page opens it — only then, and only for the
      // page. Anything else waits for a click.
      const open = event.kind === "output_files" ? event.payload.open : null
      if (typeof open === "string") {
        const item = itemForPath(open)
        if (item) onOpenCanvas(item)
      }
    },
  )
  const busy = isBusy(transcript)
  const items = foldFinished(buildTimeline(transcript), busy)

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
            className={"chip button terminal-toggle" + (terminalOpen ? " on" : "")}
            onClick={onToggleTerminal}
            title={
              (terminalOpen ? "Hide" : "Show") +
              ` terminals — ${terminalCount || "none"} running` +
              " (they open in your home directory)"
            }
          >
            <TerminalIcon />
            {terminalCount > 0 && <span className="count">{terminalCount}</span>}
          </button>
          <button
            className={"chip button canvas-toggle" + (canvasOpen ? " on" : "")}
            onClick={onToggleCanvas}
            title={(canvasOpen ? "Hide" : "Show") + " the canvas"}
          >
            <CanvasIcon />
          </button>
        </div>
      </header>

      {joinError && <div className="chat-banner">{joinError}</div>}

      {/* `output/…` links in a reply become downloads from this session. */}
      <OpenCanvas.Provider value={onOpenCanvas}>
        <OutputLink.Provider
          value={(path, label) => {
            const item = itemForPath(path)
            return item ? (
              <button type="button" className="md-download" title={`Show ${path}`} onClick={() => onOpenCanvas(item)}>
                {label}
              </button>
            ) : (
              <DownloadLink sessionId={session.id} path={path} label={label} />
            )
          }}
        >
          <Timeline
            items={items}
            sessionId={session.id}
            truncatedBefore={transcript.truncatedBefore}
            onAnswer={submit}
          />
        </OutputLink.Provider>
      </OpenCanvas.Provider>

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
  sessionId,
  truncatedBefore,
  onAnswer,
}: {
  items: TimelineItem[]
  sessionId: string
  truncatedBefore: number | null
  onAnswer: (text: string) => void
}) {
  const ref = useRef<HTMLDivElement>(null)
  const pinnedRef = useRef(true)
  // The ref decides whether to follow; this only drives the button, so a
  // scroll that does not cross the line re-renders nothing.
  const [pinned, setPinned] = useState(true)
  // Set while `toBottom` scrolls. A smooth scroll fires scroll events all the
  // way down, and judging those by position would unpin it again — and bring
  // the button straight back — before it lands.
  const jumpingRef = useRef(false)

  // Only follow the output when the user is already at the bottom; scrolling up
  // to read something while the agent streams must not yank them back down.
  const onScroll = () => {
    const el = ref.current
    if (!el) return
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 80
    if (jumpingRef.current) {
      if (!atBottom) return
      jumpingRef.current = false
    }
    pinnedRef.current = atBottom
    setPinned(atBottom)
  }

  // The user taking over mid-jump wins.
  const cancelJump = () => {
    jumpingRef.current = false
  }

  useLayoutEffect(() => {
    const el = ref.current
    if (el && pinnedRef.current) el.scrollTop = el.scrollHeight
  }, [items])

  const toBottom = () => {
    const el = ref.current
    if (!el) return
    // Pinned straight away, not when the smooth scroll lands: output arriving
    // mid-scroll should be followed, not left behind.
    pinnedRef.current = true
    setPinned(true)
    jumpingRef.current = true
    // A long transcript is tens of thousands of pixels: smooth all the way it
    // takes seconds. Cut to a screen above the end, then glide the rest, which
    // still shows which way it went.
    const end = el.scrollHeight - el.clientHeight
    if (end - el.scrollTop > el.clientHeight * 2) el.scrollTop = end - el.clientHeight
    el.scrollTo({ top: el.scrollHeight, behavior: "smooth" })
  }

  return (
    <div className="timeline-wrap">
      <div
        className="timeline"
        ref={ref}
        onScroll={onScroll}
        onWheel={cancelJump}
        onTouchStart={cancelJump}
      >
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
            <Item key={item.key} item={item} sessionId={sessionId} onAnswer={onAnswer} />
          ))}
        </div>
      </div>

      {/* Outside the scroller, so it stays put over the composer instead of
          scrolling away with the conversation. */}
      {!pinned && (
        <button
          className="to-bottom"
          onClick={toBottom}
          title="Jump to the latest"
          aria-label="Jump to the latest"
        >
          <DownIcon />
        </button>
      )}
    </div>
  )
}

function Item({
  item,
  sessionId,
  onAnswer,
}: {
  item: TimelineItem
  sessionId: string
  onAnswer: (text: string) => void
}) {
  switch (item.kind) {
    case "user":
      return (
        <div className={"bubble user" + (item.pending ? " pending" : "")}>
          {item.text.trim() !== "" && <Rich text={item.text} />}
          {item.files.length > 0 && <SentFiles sessionId={sessionId} files={item.files} />}
          {item.queued && <span className="tag">queued</span>}
          {item.origin === "phone" && <span className="tag">phone</span>}
          {item.origin === "cron" && <span className="tag">⏰ cron</span>}
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

    case "tools":
      return <ToolGroup item={item} sessionId={sessionId} onAnswer={onAnswer} />

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

    case "outputs":
      return <OutputFiles sessionId={sessionId} files={item.files} more={item.more} />

    case "turn":
      return <TurnLine item={item} />

    case "error":
      return <div className="error">{item.text}</div>

    case "notice":
      return <div className="notice">{item.text}</div>

    case "cron":
      return <CronJobs jobs={item.jobs} />
  }
}

// Shown in local time; the expression itself is UTC, and says so.
const when = (iso: string | null) =>
  iso
    ? new Date(iso).toLocaleString(undefined, {
        month: "short",
        day: "numeric",
        weekday: "short",
        hour: "2-digit",
        minute: "2-digit",
      })
    : "never"

function CronJobs({ jobs }: { jobs: CronJob[] }) {
  if (jobs.length === 0) return <div className="notice">no scheduled jobs</div>

  return (
    <div className="cron-jobs">
      {jobs.map((job) => (
        <div key={job.id} className="cron-job" title={job.prompt}>
          <div className="cron-head">
            <span className="cron-name">{job.name}</span>
            <code>{job.cron}</code>
            <span className="cron-dim">UTC</span>
          </div>
          <div className="cron-dim">
            → {job.target_title ?? job.target} · next {when(job.next_at)}
            {job.last_run_at && <> · last {when(job.last_run_at)}</>}
          </div>
          {job.last_error && <div className="cron-error">{job.last_error}</div>}
          <div className="cron-dim cron-id">{job.id}</div>
        </div>
      ))}
    </div>
  )
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

// ── File cards ─────────────────────────────────────────────────────────────

/**
 * One file as a small square: an image shows itself, anything else its
 * extension and name. The same card everywhere a file appears — waiting in the
 * composer, sent with a message, or left by the agent for download — so a file
 * looks the same on its way in and on its way out.
 */
function FileCard({
  name,
  label,
  image,
  busy = false,
  error,
  title,
  onClick,
  onRemove,
}: {
  name: string
  // Shown in place of the extension: a directory has none.
  label?: string
  // Where the thumbnail comes from: a local object URL, or a promise of one
  // for a file behind the API token. `null` for anything not an image.
  image: string | Promise<string> | null
  busy?: boolean
  error?: string | null
  title: string
  onClick?: () => void
  onRemove?: () => void
}) {
  const [src, unreachable] = useResolved(image)
  // A format the browser cannot draw (HEIC, say), or a file that could not be
  // fetched, falls back to the plain card.
  const [broken, setBroken] = useState(false)
  const failedImage = broken || unreachable
  const showImage = image !== null && !failedImage && src !== null
  const loading = busy || (image !== null && !failedImage && src === null && !error)

  return (
    <span
      className={
        "file-card" +
        (showImage ? " image" : "") +
        (error ? " failed" : "") +
        (onClick ? " clickable" : "")
      }
      title={error ? `${name}: ${error}` : title}
      onClick={onClick}
    >
      {showImage ? (
        <img src={src} alt={name} onError={() => setBroken(true)} />
      ) : (
        <>
          <span className="file-ext">{label ?? extension(name)}</span>
          <span className="file-name">{name}</span>
        </>
      )}
      {loading && <span className="file-spinner" aria-label="loading" />}
      {onRemove && (
        <button
          className="file-drop"
          title="Remove"
          onClick={(e) => {
            e.stopPropagation()
            onRemove()
          }}
        >
          ×
        </button>
      )}
    </span>
  )
}

/** A thumbnail source, settled: `[src, failed]`, src `null` until it arrives. */
function useResolved(image: string | Promise<string> | null): [string | null, boolean] {
  const [state, setState] = useState<[string | null, boolean]>([
    typeof image === "string" ? image : null,
    false,
  ])

  useEffect(() => {
    if (image === null || typeof image === "string") {
      setState([image, false])
      return
    }
    let live = true
    setState([null, false])
    image.then(
      (url) => live && setState([url, false]),
      () => live && setState([null, true]),
    )
    return () => {
      live = false
    }
  }, [image])

  return state
}

function extension(name: string): string {
  const dot = name.lastIndexOf(".")
  return dot > 0 && dot < name.length - 1 ? name.slice(dot + 1).slice(0, 5).toUpperCase() : "FILE"
}

const isImage = (contentType: string | undefined) => !!contentType?.startsWith("image/")

/** The attachments that went out with a message. */
function SentFiles({ sessionId, files }: { sessionId: string; files: AgentFile[] }) {
  return (
    <div className="files">
      {files.map((file) => (
        <FileCard
          key={file.path}
          name={file.name}
          image={isImage(file.content_type) ? blobUrl(attachmentUrl(sessionId, file.path)) : null}
          title={`${file.name} · ${formatBytes(file.size)}`}
        />
      ))}
    </div>
  )
}

/**
 * What a turn left in the output directory, one card per file; a click
 * downloads it.
 *
 * Comes from the server scanning the directory, not from the reply, so it is
 * here even when the model forgot to mention the file. See `Loom.Agent.Output`.
 */
function OutputFiles({
  sessionId,
  files,
  more,
}: {
  sessionId: string
  files: OutputFile[]
  more: number
}) {
  return (
    <div className="files outputs">
      {files.map((file) => (
        <OutputCard key={file.path} sessionId={sessionId} file={file} />
      ))}
      {more > 0 && <span className="file-card more">+{more}</span>}
    </div>
  )
}

/**
 * One output. A click shows it in the canvas when the browser can (a page, an
 * image, a video, a PDF, text), and downloads it otherwise; a directory with no
 * page downloads as a zip. The canvas has its own download button.
 */
function OutputCard({ sessionId, file }: { sessionId: string; file: OutputFile }) {
  const openCanvas = useContext(OpenCanvas)
  const [state, setState] = useState<"idle" | "busy" | { error: string }>("idle")
  const dir = file.kind === "dir"
  const name = file.path.split("/").pop() ?? file.path
  const item = itemForOutput(file)

  const download = () => {
    if (state === "busy") return
    setState("busy")
    ;(dir ? downloadAgentZip(sessionId, file.path) : downloadAgentOutput(sessionId, file.path)).then(
      () => setState("idle"),
      (e: Error) => setState({ error: e.message }),
    )
  }

  const size = formatBytes(file.size)
  const what = dir ? `${file.files} file${file.files === 1 ? "" : "s"} · ${size}` : size

  return (
    <FileCard
      name={name}
      label={dir ? (file.index ? "PAGE" : "DIR") : undefined}
      image={!dir && isImage(file.content_type) ? blobUrl(outputUrl(sessionId, file.path)) : null}
      busy={state === "busy"}
      error={typeof state === "object" ? state.error : null}
      title={
        `${item ? "Show" : dir ? "Download as a zip:" : "Download"} ${file.path} · ${what}` +
        (file.updated ? " · updated" : "")
      }
      onClick={item ? () => openCanvas(item) : download}
    />
  )
}

/**
 * A button that fetches one output and hands it to the browser as a download.
 *
 * A button, not a link: the file is behind the API token. The label stays put
 * while it downloads and the failure, if any, replaces it — a file deleted
 * since the turn is the usual one.
 */
function DownloadLink({
  sessionId,
  path,
  label,
  className = "md-download",
}: {
  sessionId: string
  path: string
  label: ReactNode
  className?: string
}) {
  const [state, setState] = useState<"idle" | "busy" | { error: string }>("idle")

  const start = () => {
    if (state === "busy") return
    setState("busy")
    downloadAgentOutput(sessionId, path).then(
      () => setState("idle"),
      (e: Error) => setState({ error: e.message }),
    )
  }

  const failed = typeof state === "object"
  return (
    <button
      type="button"
      className={className + (state === "busy" ? " busy" : "") + (failed ? " failed" : "")}
      title={failed ? state.error : `Download ${path}`}
      onClick={start}
    >
      {label}
      {failed && <span className="file-size">{state.error}</span>}
    </button>
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

/** A finished stretch of tool calls, folded; see `foldFinished`. */
function ToolGroup({
  item,
  sessionId,
  onAnswer,
}: {
  item: Extract<TimelineItem, { kind: "tools" }>
  sessionId: string
  onAnswer: (text: string) => void
}) {
  const [open, setOpen] = useState(false)
  // Which tools, in the order first used: "Bash, Read" says more than a count.
  const names = [
    ...new Set(item.steps.flatMap((s) => (s.kind === "tool" ? [s.name] : []))),
  ]

  return (
    <div className={"tool group" + (open ? " open" : "")}>
      <div className="tool-head" onClick={() => setOpen((v) => !v)}>
        <span className="tool-name">
          used {item.tools} tool{item.tools === 1 ? "" : "s"}
        </span>
        <span className="tool-summary">{names.join(", ")}</span>
        <span className={"tool-state" + (item.failed > 0 ? " bad" : "")}>
          {item.failed > 0 ? `${item.failed} ✕` : "✓"} {open ? "▾" : "▸"}
        </span>
      </div>

      {open && (
        <div className="group-steps">
          {item.steps.map((step) => (
            <Item key={step.key} item={step} sessionId={sessionId} onAnswer={onAnswer} />
          ))}
        </div>
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

// What a message can be instead of a prompt. `/compact` goes to the backend
// (Codex's adapter turns it into an RPC); `/reload` and `/cron` are loom's own.
const COMMANDS = [
  { name: "/compact", hint: "summarize the conversation to free up context" },
  { name: "/reload", hint: "reload Claude Code and Codex config: settings, MCP, skills" },
  { name: "/cron", hint: "list every scheduled job" },
]

// Only a message that *starts* with `/` is a command, and only while the first
// word is still being typed: a `/` later on is just text.
function commandMatches(text: string) {
  if (!text.startsWith("/") || /\s/.test(text)) return []
  return COMMANDS.filter((c) => c.name.startsWith(text))
}

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

  // The command menu: open while the text could still become a command, until
  // Escape dismisses it (typing anything brings it back).
  const [pick, setPick] = useState(0)
  const [dismissed, setDismissed] = useState<string | null>(null)
  const matches = dismissed === text ? [] : commandMatches(text)
  const selected = matches[Math.min(pick, matches.length - 1)]
  const complete = (name: string) => {
    setText(name)
    ref.current?.focus()
  }

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
        {selected && (
          <ul className="command-menu" role="listbox">
            {matches.map((c) => (
              <li
                key={c.name}
                role="option"
                aria-selected={c === selected}
                className={c === selected ? "on" : ""}
                // mousedown, not click: the textarea must keep focus.
                onMouseDown={(e) => {
                  e.preventDefault()
                  complete(c.name)
                }}
              >
                <span className="name">{c.name}</span>
                <span className="hint">{c.hint}</span>
              </li>
            ))}
          </ul>
        )}
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
          onChange={(e) => {
            setText(e.target.value)
            setPick(0)
            setDismissed(null)
          }}
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
            if (selected && !composingRef.current && !e.nativeEvent.isComposing) {
              const n = matches.length
              if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                e.preventDefault()
                setPick((pick + (e.key === "ArrowDown" ? 1 : n - 1)) % n)
                return
              }
              if (e.key === "Escape") {
                e.preventDefault()
                setDismissed(text)
                return
              }
              // Tab, or Enter on a half-typed name, completes it; Enter on a
              // complete one falls through and sends.
              if (e.key === "Tab" || (e.key === "Enter" && !e.shiftKey && text !== selected.name)) {
                e.preventDefault()
                complete(selected.name)
                return
              }
            }

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

function CanvasIcon() {
  return (
    <svg viewBox="0 0 24 24" width="1em" height="1em" aria-hidden fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <rect x="3" y="4" width="18" height="16" rx="2" />
      <path d="M3 9h18" />
    </svg>
  )
}

function TerminalIcon() {
  return (
    <svg viewBox="0 0 24 24" width="1.15em" height="1.15em" aria-hidden>
      <path
        d="M5 8l4 4-4 4M12 17h7"
        fill="none"
        stroke="currentColor"
        strokeWidth="2.2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function DownIcon() {
  return (
    <svg viewBox="0 0 24 24" width="1.25em" height="1.25em" aria-hidden>
      <path
        d="M12 5v14M6 13l6 6 6-6"
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
  return (
    <FileCard
      name={item.name}
      image={item.preview}
      busy={!item.file && !item.error}
      error={item.error}
      title={`${item.name} · ${formatBytes(item.size)}`}
      onRemove={onRemove}
    />
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
