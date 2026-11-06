import { Folder, Globe, MonitorSmartphone, PanelLeftClose, Plus, Search, Settings } from "lucide-react"
import { useEffect, useRef, useState } from "react"
import type { AgentBackend, AgentInfo, Device } from "./api"
import { RenameInput } from "./Confirm"
import { DevicesDialog } from "./Devices"
import { ROOT } from "./directories"
import { ago } from "./format"
import type { Push } from "./push"
import { RowMenu } from "./RowMenu"
import { SettingsDialog } from "./Settings"
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
  onMove: (id: string) => void
  // Search, and every directory: both open over the chat.
  onSearch: () => void
  onMore: () => void
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
  onMove,
  onSearch,
  onMore,
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
  const [settingsOpen, setSettingsOpen] = useState(false)
  const online = devices.filter((d) => d.online).length
  // Only the root's sessions; the rest are a directory away, under "More…".
  const root = sessions.filter((s) => (s.directory ?? ROOT) === ROOT)

  return (
    <aside className="sidebar">
      <div className="sidebar-head">
        <span className="brand">Loom</span>
        <span className="sidebar-actions">
          <button className="icon-btn" onClick={onSearch} title={vim?.on ? "Search (␣␣)" : "Search"}>
            <Search />
          </button>
          <button className="icon-btn" onClick={onCollapse} title="Hide sidebar">
            <PanelLeftClose />
          </button>
        </span>
      </div>

      <div className="session-list">
        <NewChat onCreate={onCreate} />
        {/* Only once something is filed away: the first directory is made
            from a session's "Move to…", not from here. */}
        {sessions.length > root.length && (
          <div className="session more" onClick={onMore}>
            <Folder />
            <span className="session-label">More…</span>
            <span className="session-when">{sessions.length - root.length}</span>
          </div>
        )}

        {root.map((s) => (
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
              {ago(lastActive(s))}
            </span>
            <RowMenu
              items={[
                { label: "Move to…", run: () => onMove(s.id) },
                { label: "Delete", danger: true, run: () => onDelete(s.id) },
              ]}
            />
          </div>
        ))}

      </div>

      <div className="sidebar-foot">
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
          {/* An icon like the rows beside it, so the labels line up; lit while any is online. */}
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

        {/* Theme, Vim keys and notifications: this device's preferences. */}
        <button className="devices-btn push-btn" onClick={() => setSettingsOpen(true)} title="Settings">
          <Settings />
          <span>Settings</span>
        </button>
        {settingsOpen && (
          <SettingsDialog push={push} vim={vim} onClose={() => setSettingsOpen(false)} />
        )}
      </div>
    </aside>
  )
}

/**
 * Creating a session means choosing an engine, so "New chat" asks which.
 *
 * The choice cannot be changed later — the conversation lives in that engine's
 * own store — so it is made explicitly rather than defaulted. New sessions
 * start at the root; "Move to…" files them.
 */
function NewChat({ onCreate }: { onCreate: (backend: AgentBackend) => void }) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

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
    <div className="new-session" ref={ref}>
      <div className="session new-chat" onClick={() => setOpen((v) => !v)}>
        <Plus />
        <span className="session-label">New chat</span>
      </div>
      {open && (
        <div className="backend-menu">
          <button onClick={() => choose("claude_code")}>Claude Code</button>
          <button onClick={() => choose("codex")}>Codex</button>
        </div>
      )}
    </div>
  )
}
