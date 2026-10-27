import { Bell, BellOff, Globe, Keyboard, KeyboardOff, MonitorSmartphone, PanelLeftClose, Plus, X } from "lucide-react"
import { useEffect, useRef, useState } from "react"
import type { AgentBackend, AgentInfo, Device } from "./api"
import { RenameInput } from "./Confirm"
import { DevicesDialog } from "./Devices"
import { backendShort } from "./format"
import type { Push } from "./push"
import { lastActive } from "./useLobby"

type Props = {
  sessions: AgentInfo[]
  devices: Device[]
  onUpsertDevice: (device: Device) => void
  push: Push
  // Desktop only, so null on a phone; see keys.tsx.
  vim: { on: boolean; toggle: () => void } | null
  activeId: string | null
  // The session under the keyboard's cursor while the list is walked; see App.
  cursorId: string | null
  // The session whose name is being edited in its row, and where it goes.
  renamingId: string | null
  onRenamed: (id: string, title: string | null) => Promise<void>
  onSelect: (id: string) => void
  onCreate: (backend: AgentBackend) => void
  onDelete: (id: string) => void
  onCollapse: () => void
  browserOpen: boolean
  onToggleBrowser: () => void
}

export function Sidebar({
  sessions,
  devices,
  onUpsertDevice,
  push,
  vim,
  activeId,
  cursorId,
  renamingId,
  onRenamed,
  onSelect,
  onCreate,
  onDelete,
  onCollapse,
  browserOpen,
  onToggleBrowser,
}: Props) {
  // Ages are relative, so they go stale without any new data. A local clock,
  // not a poll: nothing is fetched.
  const [, setNow] = useState(0)
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 30_000)
    return () => clearInterval(timer)
  }, [])
  const [devicesOpen, setDevicesOpen] = useState(false)
  const online = devices.filter((d) => d.online).length

  return (
    <aside className="sidebar">
      <div className="sidebar-head">
        <span className="brand">loom</span>
        <span className="sidebar-actions">
          <NewSessionButton onCreate={onCreate} />
          <button className="icon-btn" onClick={onCollapse} title="Hide sidebar">
            <PanelLeftClose />
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
            ref={s.id === cursorId ? (el) => el?.scrollIntoView({ block: "nearest" }) : undefined}
            className={
              "session" + (s.id === activeId ? " active" : "") + (s.id === cursorId ? " cursor" : "")
            }
            onClick={() => onSelect(s.id)}
          >
            <span className={"dot " + s.status} title={s.status} />
            {s.id === renamingId ? (
              <RenameInput value={s.title ?? s.id} stem={false} onDone={(title) => onRenamed(s.id, title)} />
            ) : (
              <span className="session-label">{s.title ?? s.id}</span>
            )}
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
              {backendShort(s.backend)}
            </span>
            <button
              className="session-del"
              title="Delete session and its history"
              onClick={(e) => {
                e.stopPropagation()
                onDelete(s.id)
              }}
            >
              <X />
            </button>
          </div>
        ))}
      </div>

      <div className="sidebar-foot">
        {vim && (
          <button
            className={"devices-btn push-btn" + (vim.on ? " on" : "")}
            onClick={vim.toggle}
            title={vim.on ? "Vim mode is on; ? lists the keys. Click to turn it off." : "Turn on Vim mode: keys for the panes, ? lists them"}
          >
            {vim.on ? <Keyboard /> : <KeyboardOff />}
            <span>Vim mode</span>
            <span className="devices-count">{vim.on ? "on" : "off"}</span>
          </button>
        )}

        <PushButton push={push} />

        {/* Loom's own browser, the one agents drive: taking it over is how a
            site gets logged in to once and stays logged in. */}
        <button
          className={"devices-btn push-btn" + (browserOpen ? " on" : "")}
          onClick={onToggleBrowser}
          title="Loom's browser: log in to a site, or get past a check for the agents"
        >
          <Globe />
          <span>Browser</span>
          <span className="devices-count">{browserOpen ? "open" : ""}</span>
        </button>

        {/* The user's own machines, reachable by agents through loom-node. */}
        <button
          className={"devices-btn push-btn" + (online > 0 ? " on" : "")}
          onClick={() => setDevicesOpen(true)}
          title="Devices"
        >
          {/* An icon like the two above, so the labels line up; lit while any is online. */}
          <MonitorSmartphone />
          <span>Devices</span>
          <span className="devices-count">
            {online}/{devices.length}
          </span>
        </button>
        {devicesOpen && (
          <DevicesDialog
            devices={devices}
            onUpsert={onUpsertDevice}
            onClose={() => setDevicesOpen(false)}
          />
        )}
      </div>
    </aside>
  )
}

const PUSH_HINT: Record<Push["state"], string> = {
  on: "This device is notified when a turn ends. Click to stop.",
  off: "Get a notification on this device when a turn ends",
  denied: "Notifications are blocked for this site in the browser's settings",
  unsupported: "On an iPhone, add Loom to the Home Screen and open it from there to get notifications",
}

/** Notifications for this device, on or off; see `usePush`. */
function PushButton({ push }: { push: Push }) {
  const on = push.state === "on"
  const Icon = on ? Bell : BellOff
  return (
    <button
      className={"devices-btn push-btn" + (on ? " on" : "")}
      onClick={push.toggle}
      disabled={push.busy || push.state === "denied" || push.state === "unsupported"}
      title={push.error ?? PUSH_HINT[push.state]}
    >
      <Icon />
      <span>Notifications</span>
      <span className="devices-count">
        {push.error ? "failed" : push.busy ? "…" : on ? "on" : push.state === "off" ? "off" : "n/a"}
      </span>
    </button>
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
        <Plus />
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

function when(ms: number): string {
  const mins = Math.floor((Date.now() - ms) / 60000)
  if (mins < 1) return "now"
  if (mins < 60) return `${mins}m`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `${hours}h`
  return `${Math.floor(hours / 24)}d`
}
