import {
  ChevronDown,
  ChevronRight,
  Folder,
  FolderInput,
  FolderMinus,
  FolderOpen,
  Globe,
  LayoutGrid,
  MonitorSmartphone,
  PanelLeftClose,
  Plus,
  Search,
  Settings,
  Trash2,
} from "lucide-react"
import { useEffect, useRef, useState } from "react"
import type { AgentBackend, AgentInfo, Device } from "./api"
import { RenameInput } from "./Confirm"
import { DevicesDialog } from "./Devices"
import { filed, ROOT } from "./directories"
import { ago } from "./format"
import { dirName, MoveTargets } from "./MovePicker"
import type { Push } from "./push"
import { type MenuItem, RowMenu } from "./RowMenu"
import { SettingsDialog } from "./Settings"
import { useDragOrder } from "./useDragOrder"
import { lastActive } from "./useLobby"

// The directories unfolded in the sidebar, and whether the section itself is
// (it starts folded), on this device.
const UNFOLDED_KEY = "loom.unfolded"
const DIRS_OPEN_KEY = "loom.dirsOpen"

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
  // A phone's "Move to directory": the picker over everything. A desktop moves
  // from the menu's own submenu, straight to `onMoveTo`.
  onMove: (id: string) => void
  onMoveTo: (id: string, directory: string) => Promise<void>
  onRenameDirectory: (from: string, to: string) => Promise<void>
  // The directories' order, shared by every device; a drag sends a new one.
  directoryOrder: string[]
  onOrderDirectories: (order: string[]) => void
  narrow: boolean
  onSearch: () => void
  onCollapse: () => void
  browserOpen: boolean
  onToggleBrowser: () => void
  appsOpen: boolean
  onToggleApps: () => void
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
  onMoveTo,
  onRenameDirectory,
  directoryOrder,
  onOrderDirectories,
  narrow,
  onSearch,
  onCollapse,
  browserOpen,
  onToggleBrowser,
  appsOpen,
  onToggleApps,
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
  // Directories first, in the order dragged into, each folded or unfolded as
  // last left on this device; then Recents, what is in none. The sessions in a
  // directory go by activity, like Recents; only the directories are dragged.
  const dirs = filed(sessions, directoryOrder)
  const drag = useDragOrder(dirs, onOrderDirectories)
  const root = sessions.filter((s) => (s.directory ?? ROOT) === ROOT)
  const [unfolded, setUnfolded] = useState<string[]>(() => {
    try {
      return JSON.parse(localStorage.getItem(UNFOLDED_KEY) ?? "[]") as string[]
    } catch {
      return []
    }
  })
  useEffect(() => localStorage.setItem(UNFOLDED_KEY, JSON.stringify(unfolded)), [unfolded])
  const [dirsOpen, setDirsOpen] = useState(() => localStorage.getItem(DIRS_OPEN_KEY) === "1")
  useEffect(() => localStorage.setItem(DIRS_OPEN_KEY, dirsOpen ? "1" : "0"), [dirsOpen])
  const fold = (dir: string) =>
    setUnfolded((open) => (open.includes(dir) ? open.filter((d) => d !== dir) : [...open, dir]))
  const [renamingDir, setRenamingDir] = useState<string | null>(null)
  const renameDir = async (from: string, name: string | null) => {
    setRenamingDir(null)
    const to = name === null ? "" : dirName(name)
    if (to === "" || to === from) return
    await onRenameDirectory(from, to)
    setUnfolded((open) => open.map((d) => (d === from ? to : d)))
  }

  const menu = (s: AgentInfo): MenuItem[] => {
    const dir = s.directory ?? ROOT
    const move: MenuItem = narrow
      ? { label: "Move to directory", icon: <FolderInput />, run: () => onMove(s.id) }
      : {
          label: "Move to directory",
          icon: <FolderInput />,
          sub: (close) => (
            <MoveTargets
              dirs={dirs}
              current={dir}
              onPick={async (to) => {
                await onMoveTo(s.id, to)
                close()
              }}
            />
          ),
        }
    return [
      { label: "Delete", danger: true, icon: <Trash2 />, run: () => onDelete(s.id) },
      { divider: true },
      ...(dir === ROOT
        ? [move]
        : [
            { heading: dir },
            move,
            { label: "Remove from directory", icon: <FolderMinus />, run: () => void onMoveTo(s.id, ROOT) },
          ]),
    ]
  }

  const row = (s: AgentInfo, inDir = false) => (
    <div
      key={s.id}
      ref={s.id === cursorId ? (el) => el?.scrollIntoView({ block: "nearest" }) : undefined}
      className={
        "session" +
        (inDir ? " in-dir" : "") +
        (s.id === activeId ? " active" : "") +
        (s.id === cursorId ? " cursor" : "")
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
      <span className="session-when" title={"last active " + new Date(lastActive(s)).toLocaleString()}>
        {ago(lastActive(s))}
      </span>
      <RowMenu items={menu(s)} />
    </div>
  )

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

        {dirs.length > 0 && (
          <>
            <div className="session-section fold" onClick={() => setDirsOpen((open) => !open)}>
              Directories
              {dirsOpen ? <ChevronDown /> : <ChevronRight />}
            </div>
            {dirsOpen && drag.order.map((d) => {
              const open = unfolded.includes(d)
              const here = sessions
                .filter((s) => s.directory === d)
                .sort((a, b) => lastActive(b) - lastActive(a))
              return (
                <div key={d}>
                  <div
                    ref={drag.row(d)}
                    className={"session directory" + (drag.dragging === d ? " dragging" : "")}
                    onPointerDown={renamingDir === d ? undefined : drag.start(d)}
                    onContextMenu={(e) => e.preventDefault()}
                    onClick={() => drag.clicked() || fold(d)}
                  >
                    {open ? <FolderOpen /> : <Folder />}
                    {renamingDir === d ? (
                      <RenameInput value={d} stem={false} onDone={(name) => renameDir(d, name)} />
                    ) : (
                      <span className="session-label">{d}</span>
                    )}
                    {!open && <span className="session-when">{here.length}</span>}
                    <RowMenu items={[{ label: "Rename", run: () => setRenamingDir(d) }]} />
                  </div>
                  {open && here.map((s) => row(s, true))}
                </div>
              )
            })}
            <div className="session-section recents">Recents</div>
          </>
        )}

        {root.map((s) => row(s))}
      </div>

      <div className="sidebar-foot">
        {/* What the agents distilled into programs, in ~/apps/: no model runs
            when one is opened. */}
        <button
          className={"devices-btn push-btn" + (appsOpen ? " on" : "")}
          onClick={onToggleApps}
          title="Apps"
        >
          <LayoutGrid />
          <span>Apps</span>
        </button>

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
 * start in Recents; "Move to directory" files them.
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
