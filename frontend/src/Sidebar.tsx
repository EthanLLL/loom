import { useEffect, useRef, useState } from "react"
import type { AgentBackend, AgentInfo } from "./api"
import { lastActive } from "./useLobby"

type Props = {
  sessions: AgentInfo[]
  activeId: string | null
  onSelect: (id: string) => void
  onCreate: (backend: AgentBackend) => void
  onDelete: (id: string) => void
  onCollapse: () => void
}

export function Sidebar({
  sessions,
  activeId,
  onSelect,
  onCreate,
  onDelete,
  onCollapse,
}: Props) {
  // Ages are relative, so they go stale without any new data. A local clock,
  // not a poll: nothing is fetched.
  const [, setNow] = useState(0)
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 30_000)
    return () => clearInterval(timer)
  }, [])

  return (
    <aside className="sidebar">
      <div className="sidebar-head">
        <span className="brand">loom</span>
        <span className="sidebar-actions">
          <NewSessionButton onCreate={onCreate} />
          <button className="icon-btn" onClick={onCollapse} title="Hide sidebar">
            ‹
          </button>
        </span>
      </div>

      <div className="session-list">
        {sessions.length === 0 && (
          <div className="session-empty">No sessions yet.</div>
        )}

        {sessions.map((s) => (
          <div
            key={s.id}
            className={"session" + (s.id === activeId ? " active" : "")}
            onClick={() => onSelect(s.id)}
          >
            <span className={"dot " + s.status} title={s.status} />
            <span className="session-label">{s.title ?? s.id}</span>
            {s.queued > 0 && (
              <span className="session-queued" title="queued messages">
                {s.queued}
              </span>
            )}
            <span
              className="session-when"
              title={"last active " + new Date(lastActive(s)).toLocaleString()}
            >
              {when(lastActive(s))}
            </span>
            {/* Which engine is running it is not a detail: the two behave
                differently and the binding is permanent. */}
            <span className={"session-backend " + s.backend}>
              {SHORT[s.backend] ?? s.backend}
            </span>
            <button
              className="session-del"
              title="Delete session and its history"
              onClick={(e) => {
                e.stopPropagation()
                onDelete(s.id)
              }}
            >
              ×
            </button>
          </div>
        ))}
      </div>
    </aside>
  )
}

/**
 * Creating a session means choosing an engine, so there is no plain "+".
 *
 * The choice cannot be changed later — the conversation lives in that engine's
 * own store — so it is made explicitly rather than defaulted.
 */
function NewSessionButton({
  onCreate,
}: {
  onCreate: (backend: AgentBackend) => void
}) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLSpanElement>(null)

  useEffect(() => {
    if (!open) return
    const onAway = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener("mousedown", onAway)
    return () => document.removeEventListener("mousedown", onAway)
  }, [open])

  const choose = (backend: AgentBackend) => {
    setOpen(false)
    onCreate(backend)
  }

  return (
    <span className="new-session" ref={ref}>
      <button
        className="icon-btn"
        onClick={() => setOpen((v) => !v)}
        title="New session"
      >
        +
      </button>
      {open && (
        <div className="backend-menu">
          <button onClick={() => choose("claude_code")}>Claude Code</button>
          <button onClick={() => choose("codex")}>Codex</button>
        </div>
      )}
    </span>
  )
}

const SHORT: Record<string, string> = {
  claude_code: "cc",
  codex: "cx",
}

function when(ms: number): string {
  const mins = Math.floor((Date.now() - ms) / 60000)
  if (mins < 1) return "now"
  if (mins < 60) return `${mins}m`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `${hours}h`
  return `${Math.floor(hours / 24)}d`
}
