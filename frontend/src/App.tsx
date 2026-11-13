import { ArrowLeft01Icon, Cancel01Icon, Maximize01Icon, Minimize01Icon, PlusSignIcon } from "@hugeicons/core-free-icons"
import { lazy, Suspense, useEffect, useRef, useState } from "react"
import { Button } from "@/components/ui/button"
import { BackendIcon } from "./BackendIcon"
import { Canvas } from "./Canvas"
import { moved, touches, type CanvasItem } from "./canvasItems"
import { Confirm } from "./Confirm"
import { Chat } from "./Chat"
import { Apps } from "./Apps"
import { filed, ROOT } from "./directories"
import type { TreeNav } from "./FileBrowser"
import { KeyHelp, useGlobalKey, useKeys, WhichKey, type Keymap } from "./keys"
import { Login } from "./Login"
import { MovePicker } from "./MovePicker"
import { PaneButton, PaneHead, PaneTitle } from "./Pane"
import { usePush, useVisible } from "./push"
import { Search } from "./Search"
import { Sidebar, SidebarHandle, WIDE } from "./Sidebar"
import { SidebarProvider } from "@/components/ui/sidebar"
import { Terminal } from "./Terminal"
// noVNC is only for the browser pane, so it loads when that is first opened.
const Browser = lazy(() => import("./Browser").then((m) => ({ default: m.Browser })))
import { useLobby } from "./useLobby"
import { ViewportReadout } from "./ViewportReadout"
import { useCompact, useNarrow } from "./useNarrow"
import {
  createAgent,
  createSession,
  deleteAgent,
  deleteSession,
  checkAuth,
  renameAgent,
  getToken,
  listSessions,
  moveAgent,
  moveDirectory,
  onUnauthorized,
  type AgentBackend,
} from "./api"
import { dropSocket } from "./socket"
import "./App.css"

const SIDEBAR_KEY = "loom_sidebar_open"
const SIDEBAR_SCALE_KEY = "loom_sidebar_scale"
const CANVAS_KEY = "loom_canvas"
const TREE_KEY = "loom_canvas_tree"
const VIM_KEY = "loom_vim"

// The right-hand side shows one thing at a time: the terminals, the canvas,
// the browser or the apps.
type Side = "terminal" | "canvas" | "browser" | "apps" | null

function loadCanvases(): Record<string, CanvasItem> {
  try {
    return JSON.parse(localStorage.getItem(CANVAS_KEY) ?? "{}")
  } catch {
    return {}
  }
}

function takeSessionParam(): string | null {
  const url = new URL(window.location.href)
  const id = url.searchParams.get("session")
  if (id) {
    url.searchParams.delete("session")
    history.replaceState(null, "", url.pathname + url.search + url.hash)
  }
  return id
}

function App() {
  const [authed, setAuthed] = useState(!!getToken())
  // Pushed by the server as sessions change; see `useLobby`.
  const push = usePush(authed)
  const visible = useVisible()
  // Opened from a notification: `?session=` names the session to show, and
  // goes from the address bar once read.
  const [activeId, setActiveId] = useState<string | null>(takeSessionParam)
  const {
    sessions,
    devices,
    apps,
    directoryOrder,
    orderDirectories,
    upsertDevice,
    loaded,
    upsert,
    drop,
    search,
  } = useLobby(
    authed,
    push.endpoint ? { endpoint: push.endpoint, session: visible ? activeId : null } : null,
  )
  const narrow = useNarrow()
  const compact = useCompact()

  // The token outlives the app now (see `getToken`), so a stored one can be
  // dead. Checked once on open, and any 401 later lands here too.
  useEffect(() => {
    onUnauthorized(() => {
      dropSocket()
      setAuthed(false)
    })
    void checkAuth()
  }, [])

  // Remembered, because you collapse it once and want it to stay collapsed
  // across reloads. Desktop only: on a phone the sidebar is a drawer over the
  // chat, which starts closed and closes again once you pick something.
  const [sidebarOpen, setSidebarOpen] = useState(
    () => localStorage.getItem(SIDEBAR_KEY) !== "0",
  )
  const [drawerOpen, setDrawerOpen] = useState(false)
  // Whether the sidebar was dragged a third wider than its own (see
  // `SidebarHandle`), on this device.
  const [sidebarScale, setSidebarScale] = useState(() => (Number(localStorage.getItem(SIDEBAR_SCALE_KEY)) > 1 ? WIDE : 1))
  useEffect(() => localStorage.setItem(SIDEBAR_SCALE_KEY, String(sidebarScale)), [sidebarScale])

  const [side, setSide] = useState<Side>(null)
  const terminalOpen = side === "terminal"
  // Mounted once first opened, so an app keeps its state while the canvas or
  // the terminals are shown instead.
  const [appsUsed, setAppsUsed] = useState(false)
  useEffect(() => {
    if (side === "apps") setAppsUsed(true)
  }, [side])

  // The right-hand column across the whole window, chat and sidebar hidden —
  // for presenting a page from the canvas, or a terminal with room. Not on a
  // phone, where the column covers the chat already. Closing the column ends
  // it, so it never comes back on its own.
  const [full, setFull] = useState(false)
  const maximized = full && side !== null && !narrow
  useEffect(() => {
    if (side === null) setFull(false)
  }, [side])
  // Esc leaves it, except from a shell, where Esc is the editor's.
  useEffect(() => {
    if (!maximized) return
    const onKey = (e: KeyboardEvent) => {
      // Not from a shell, where Esc is the editor's, nor one something else
      // took already (a rename box putting the old name back).
      if (e.key !== "Escape" || e.defaultPrevented) return
      if ((e.target as Element | null)?.closest?.(".terminal-pane")) return
      setFull(false)
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [maximized])
  const toggleFull = () => setFull((f) => !f)
  const setTerminalOpen = (open: boolean) => setSide(open ? "terminal" : null)

  // What each session's canvas shows. Per session and kept across switching
  // away (to the terminals, another session, a reload): coming back finds it
  // as it was. Replaced only when something new is opened in it.
  const [canvases, setCanvases] = useState(loadCanvases)
  useEffect(() => {
    localStorage.setItem(CANVAS_KEY, JSON.stringify(canvases))
  }, [canvases])

  // Opening is also reading again: a second click on a file rewritten since
  // the first shows what is there now.
  const openCanvas = (sessionId: string, item: CanvasItem) => {
    setCanvases((all) => ({ ...all, [sessionId]: { ...item, rev: Date.now() } }))
    setSide("canvas")
  }
  // A turn rewrote what the canvas shows: read it again, without opening the
  // canvas if it is closed.
  const refreshCanvas = (sessionId: string, outputs: string[]) =>
    setCanvases((all) => {
      const item = all[sessionId]
      return item && touches(item, outputs)
        ? { ...all, [sessionId]: { ...item, rev: Date.now() } }
        : all
    })
  // Something renamed or deleted in the file tree: the canvas follows it to its
  // new name, or lets go of it.
  const followCanvas = (sessionId: string, source: "output" | "files", from: string, to: string | null) =>
    setCanvases((all) => {
      const item = all[sessionId]
      const next = item && moved(item, source, from, to)
      if (next === undefined) return all
      const { [sessionId]: _gone, ...rest } = all
      return next === null ? rest : { ...all, [sessionId]: { ...next, rev: Date.now() } }
    })
  const toggleCanvas = () => setSide((s) => (s === "canvas" ? null : "canvas"))
  // The canvas's file tree, beside what it shows. Remembered like the sidebar.
  const [treeOpen, setTreeOpen] = useState(() => localStorage.getItem(TREE_KEY) !== "0")
  useEffect(() => {
    localStorage.setItem(TREE_KEY, treeOpen ? "1" : "0")
  }, [treeOpen])
  // Bumped when the active session's files may have changed, so the canvas's
  // file browser lists them again.
  const [filesRev, setFilesRev] = useState(0)
  // PTY session ids, top to bottom in the right-hand column.
  const [ptyIds, setPtyIds] = useState<string[]>([])
  const openingTerminal = useRef(false)

  useEffect(() => {
    localStorage.setItem(SIDEBAR_KEY, sidebarOpen ? "1" : "0")
  }, [sidebarOpen])

  // Open the first session once the list arrives, and move off a session that
  // disappears — deleted here or on another device.
  useEffect(() => {
    if (!loaded) return
    setActiveId((current) =>
      current && sessions.some((s) => s.id === current)
        ? current
        : (sessions[0]?.id ?? null),
    )
  }, [loaded, sessions])

  // The backend is chosen here and never again: the conversation lives in that
  // engine's own store, so there is nothing to migrate if it changes.
  const create = async (backend: AgentBackend, profile?: string) => {
    const session = await createAgent(backend, profile)
    upsert(session)
    setActiveId(session.id)
    leaveApps()
    setDrawerOpen(false)
  }

  const select = (id: string) => {
    setActiveId(id)
    leaveApps()
    setDrawerOpen(false)
  }
  // On a phone the apps cover the chat, so picking a session closes them;
  // beside it, they stay.
  const leaveApps = () => {
    if (narrow) setSide((s) => (s === "apps" ? null : s))
  }

  // A notification tapped while the app is already open: the worker names the
  // session rather than opening a second window.
  useEffect(() => {
    const onMessage = (e: MessageEvent) => {
      if (e.data?.type === "open-session" && typeof e.data.session === "string") {
        setActiveId(e.data.session)
        setDrawerOpen(false)
      }
    }
    navigator.serviceWorker?.addEventListener("message", onMessage)
    return () => navigator.serviceWorker?.removeEventListener("message", onMessage)
  }, [])

  // Asked first, always: the history does not come back. See `Confirm`.
  const [deleting, setDeleting] = useState<string | null>(null)
  const remove = (id: string) => setDeleting(id)
  const [renaming, setRenaming] = useState<string | null>(null)

  // ── Directories and search ───────────────────────────────────────────────
  //
  // Directories are prefixes on the sessions (see directories.ts); moving
  // something only rewrites them, and the lobby pushes the result.
  const [searching, setSearching] = useState(false)
  // A phone's "Move to directory", for this session.
  const [moving, setMoving] = useState<string | null>(null)
  const moveTo = async (id: string, directory: string) => upsert(await moveAgent(id, directory))
  const openOver = (open: (on: boolean) => void) => {
    setDrawerOpen(false)
    open(true)
  }
  const renamed = async (id: string, title: string | null) => {
    if (title !== null) upsert(await renameAgent(id, title))
    setRenaming(null)
  }

  // ── Terminals ────────────────────────────────────────────────────────────
  //
  // All of them live in the right-hand column, stacked. Hiding the column
  // leaves them running: the shells are server-side and a hidden pane just has
  // zero size, which the Terminal component already handles.

  // Line the column up with the shells the server is actually running: a shell
  // may have been opened on another device, or have exited while the column
  // was hidden. Shells already on screen keep their places; new ones go after
  // them, oldest first. Returns how many there are now.
  const syncTerminals = async (current: string[]) => {
    const live = await listSessions().catch(() => null)
    if (live === null) return current.length

    const alive = new Set(live.map((s) => s.id))
    const kept = current.filter((id) => alive.has(id))
    const added = [...live]
      .sort((a, b) => a.created_at - b.created_at)
      .map((s) => s.id)
      .filter((id) => !kept.includes(id))
    setPtyIds([...kept, ...added])
    return kept.length + added.length
  }

  // Up front, so the header's count is right before the column is ever opened.
  // The panes mount hidden and stay idle: a terminal only joins its channel
  // once it has a size.
  useEffect(() => {
    if (authed) void syncTerminals([])
  }, [authed])

  const toggleTerminal = async () => {
    if (terminalOpen) {
      setTerminalOpen(false)
      return
    }

    // Guarded against a double click: the second call would see no shells
    // yet and spawn one nobody asked for.
    if (openingTerminal.current) return
    openingTerminal.current = true

    try {
      // Only when nothing is running is a new one started.
      if ((await syncTerminals(ptyIds)) === 0) {
        setPtyIds([(await createSession("terminal")).id])
      }
    } finally {
      openingTerminal.current = false
    }

    setTerminalOpen(true)
  }

  const addTerminal = async () => {
    const session = await createSession("terminal")
    setPtyIds((ids) => [...ids, session.id])
  }

  const closeTerminal = async (id: string) => {
    const next = ptyIds.filter((p) => p !== id)
    setPtyIds(next)
    // Nothing left to show, so drop the column rather than leave a gap.
    if (next.length === 0) setTerminalOpen(false)
    await deleteSession(id).catch(() => {})
  }

  // ── Keys ─────────────────────────────────────────────────────────────────
  //
  // See keys.tsx and docs/keys.md. The session list has a cursor of its own
  // while it is being walked with j/k; Enter opens the session under it.
  //
  // The canvas's file tree is walked the same way, by `treeNav`, which the
  // tree fills in.
  // Off until turned on: not everyone wants single keys to do things.
  const [vim, setVim] = useState(() => localStorage.getItem(VIM_KEY) === "1")
  useEffect(() => {
    localStorage.setItem(VIM_KEY, vim ? "1" : "0")
  }, [vim])
  const [listCursor, setListCursor] = useState<string | null>(null)
  const [treeWalk, setTreeWalk] = useState(false)
  const treeNav = useRef<TreeNav | null>(null)
  const [help, setHelp] = useState(false)
  const walking = listCursor !== null || treeWalk
  useEffect(() => {
    if (!walking) return
    // A dialog the walk opened (deleting, asks first) is still part of it.
    const away = (e: MouseEvent) => {
      if ((e.target as Element | null)?.closest?.("[role=dialog], [role=alertdialog]")) return
      setListCursor(null)
      setTreeWalk(false)
    }
    window.addEventListener("mousedown", away)
    return () => window.removeEventListener("mousedown", away)
  }, [walking])
  // Nothing to walk once the tree is out of sight.
  useEffect(() => {
    if (side !== "canvas" || !treeOpen) setTreeWalk(false)
  }, [side, treeOpen])

  const timeline = () => document.querySelector<HTMLElement>(".timeline")
  const scroll = (by: (el: HTMLElement) => number, smooth = false) => {
    const el = timeline()
    el?.scrollBy({ top: by(el), behavior: smooth ? "smooth" : "instant" })
  }
  const step = (ids: string[], from: string | null, by: number) => {
    if (ids.length === 0) return null
    const at = from === null ? -1 : ids.indexOf(from)
    return ids[at === -1 ? 0 : Math.min(ids.length - 1, Math.max(0, at + by))]
  }
  // What j/k, J/K walk: the list as the sidebar shows it, the root's sessions.
  const ids = sessions.filter((s) => (s.directory ?? ROOT) === ROOT).map((s) => s.id)

  // Into the columns either side of the chat, opening them as needed: `h` and
  // `␣b` to the session list, `l` and `␣e` to the file tree.
  const toList = () => {
    setTreeWalk(false)
    setFull(false)
    setSidebarOpen(true)
    if (compact) setSide(null)
    setListCursor(activeId ?? ids[0] ?? null)
  }
  const toTree = () => {
    setListCursor(null)
    setSide("canvas")
    setTreeOpen(true)
    setTreeWalk(true)
  }

  const leader: Keymap = {
    "Space Space": { desc: "search titles and what was said", run: () => openOver(setSearching) },
    "Space e": {
      desc: "file tree (j/k, h/l, Enter)",
      run: () => {
        if (!treeWalk) return toTree()
        setTreeWalk(false)
        setTreeOpen(false)
      },
    },
    "Space b": {
      desc: "session list (j/k, Enter)",
      run: () => {
        if (listCursor === null) return toList()
        setListCursor(null)
        setSidebarOpen(false)
      },
    },
    "Space t": { desc: "terminal", run: () => void toggleTerminal() },
    "Space c": { desc: "canvas", run: toggleCanvas },
    "Space f": { desc: "full window", run: () => side !== null && toggleFull() },
    "Space n c": { desc: "new Claude Code session", run: () => void create("claude_code") },
    "Space n x": { desc: "new Codex session", run: () => void create("codex") },
    "Space n k": { desc: "new Kiro session", run: () => void create("kiro") },
  }
  const keymap: Keymap = treeWalk
    ? {
        j: { desc: "next file", run: () => treeNav.current?.move(1) },
        k: { desc: "previous file", run: () => treeNav.current?.move(-1) },
        h: {
          desc: "fold, up to the folder, or back to the chat",
          run: () => treeNav.current?.left() || setTreeWalk(false),
        },
        l: { desc: "unfold, or open", run: () => treeNav.current?.right() },
        Enter: { desc: "open the file, or fold the folder", run: () => treeNav.current?.enter() },
        Esc: { desc: "leave the tree", run: () => setTreeWalk(false) },
        d: { desc: "delete it (asks)", run: () => treeNav.current?.remove() },
        r: { desc: "rename it", run: () => treeNav.current?.rename() },
        ...leader,
      }
    : listCursor !== null
      ? {
          j: { desc: "next session", run: () => setListCursor((c) => step(ids, c, 1)) },
          k: { desc: "previous session", run: () => setListCursor((c) => step(ids, c, -1)) },
          Enter: {
            desc: "open it",
            run: () => {
              select(listCursor)
              setListCursor(null)
            },
          },
          Esc: { desc: "leave the list", run: () => setListCursor(null) },
          d: { desc: "delete the session (asks)", run: () => setDeleting(listCursor) },
          r: { desc: "rename the session", run: () => setRenaming(listCursor) },
          l: { desc: "back to the chat", run: () => setListCursor(null) },
          ...leader,
        }
      : {
          i: {
            desc: "type a message",
            run: () => document.querySelector<HTMLElement>(".composer-input")?.focus(),
          },
          j: { desc: "scroll down", run: () => scroll(() => 60) },
          k: { desc: "scroll up", run: () => scroll(() => -60) },
          "C-d": { desc: "half a page down", run: () => scroll((el) => el.clientHeight / 2, true) },
          "C-u": { desc: "half a page up", run: () => scroll((el) => -el.clientHeight / 2, true) },
          "g g": { desc: "top", run: () => timeline()?.scrollTo({ top: 0 }) },
          G: { desc: "bottom", run: () => scroll((el) => el.scrollHeight) },
          h: { desc: "to the session list", run: toList },
          l: { desc: "to the file tree", run: toTree },
          J: { desc: "next session", run: () => activeId && select(step(ids, activeId, 1)!) },
          K: { desc: "previous session", run: () => activeId && select(step(ids, activeId, -1)!) },
          ...leader,
          "?": { desc: "all keys", run: () => setHelp(true) },
        }
  const keysOn = vim && authed && loaded && !narrow
  const pending = useKeys(keysOn, keymap)
  useGlobalKey(keysOn, (e) => e.ctrlKey && e.code === "Backquote", () => void toggleTerminal())

  if (!authed) return <Login onSuccess={() => setAuthed(true)} />
  if (!loaded)
    return (
      <div className="flex h-full items-center justify-center bg-background font-sans text-muted-foreground">
        Connecting…
      </div>
    )

  const active = sessions.find((s) => s.id === activeId) ?? null

  // The right-hand column: the terminals stacked top to bottom, the canvas,
  // the browser or the apps — one at a time; a 16:9 screen has no room for
  // two beside the chat. 6 of 10 to the chat's 4, or even halves when the
  // sidebar gave way for it (`compact`). Deliberately not scrolling: a
  // scrollbar would narrow the column when it appeared, which re-fits every
  // terminal, which reflows their content — a loop that shows up as flicker.
  // Panes share the height instead; past a handful they get small, which is
  // the cue to close one. On a touch screen in a card it keeps its content
  // clear of the round bottom corners; on a phone, where it covers the
  // screen, clear of the status bar and the home indicator.
  const column =
    "flex min-h-0 min-w-0 flex-col overflow-hidden sm:pointer-coarse:pb-3 max-sm:absolute max-sm:inset-0 max-sm:z-10 max-sm:pt-[env(safe-area-inset-top)] max-sm:pb-[env(safe-area-inset-bottom)] " +
    (maximized ? "flex-1" : compact ? "flex-[0_0_50%]" : "flex-[0_0_60%]") +
    CARD

  const sidebar = (
    <Sidebar
      sessions={sessions}
      devices={devices}
      onUpsertDevice={upsertDevice}
      push={push}
      vim={narrow ? null : { on: vim, toggle: () => setVim((v) => !v) }}
      activeId={activeId}
      cursorId={listCursor}
      renamingId={renaming}
      onRenamed={renamed}
      onSelect={select}
      onCreate={create}
      onDelete={remove}
      onMove={(id) => {
        setDrawerOpen(false)
        setMoving(id)
      }}
      onMoveTo={moveTo}
      onRenameDirectory={moveDirectory}
      directoryOrder={directoryOrder}
      onOrderDirectories={orderDirectories}
      narrow={narrow}
      onSearch={() => openOver(setSearching)}
      browserOpen={side === "browser"}
      onToggleBrowser={() => {
        if (narrow) setDrawerOpen(false)
        setSide((s) => (s === "browser" ? null : "browser"))
      }}
      appsOpen={side === "apps"}
      onToggleApps={() => {
        if (narrow) setDrawerOpen(false)
        setSide((s) => (s === "apps" ? null : "apps"))
      }}
    />
  )

  return (
    // On a desktop the sidebar and the columns are cards on the sidebar's
    // colour; on a phone the sidebar is a drawer over the chat, which has the
    // whole screen. Its open states are kept here: see `SidebarProvider`.
    <SidebarProvider
      // Short of room, the sidebar and the column take turns: the column
      // pushes it shut while open, and opening it closes the column (which
      // stays mounted, as it was). It comes back when the column closes.
      open={sidebarOpen && !maximized && !(compact && side !== null)}
      onOpenChange={(open) => {
        if (open && compact) setSide(null)
        setSidebarOpen(open)
      }}
      openMobile={drawerOpen}
      onOpenMobileChange={setDrawerOpen}
      style={{ "--sidebar-width": `calc(17rem * ${sidebarScale})` } as React.CSSProperties}
      className={
        // `app`, `side-open` and `maximized` are for the title-bar rules in
        // App.css, which follow whichever column is outermost.
        "app bg-sidebar font-sans text-foreground" + (side !== null ? " side-open" : "") + (maximized ? " maximized" : "")
      }
    >
      {sidebar}
      {!maximized && <SidebarHandle scale={sidebarScale} onScale={setSidebarScale} />}

      {/* sidebar | chat | column — always side by side, at every width. The
          target device is a foldable, so a narrow viewport is a tall one
          rather than a reason to restack: a terminal under the chat would
          leave both halves too short to be useful. The sidebar collapses
          instead, and on a phone the column covers the chat. */}
      <main className="relative flex min-h-0 min-w-0 flex-1 sm:gap-2 sm:p-2 sm:peer-data-[state=expanded]:pl-0">
        {/* Maximized, the column takes the window; the chat stays mounted,
            so its channel is still joined when it comes back. */}
        <div className={"flex min-h-0 min-w-0 flex-1" + (maximized ? " hidden" : "") + CARD}>
          {active ? (
            // Keyed by id so switching sessions rebuilds the channel and the
            // transcript rather than mixing two conversations.
            <Chat
              key={active.id}
              session={active}
              terminalOpen={terminalOpen}
              terminalCount={ptyIds.length}
              onToggleTerminal={toggleTerminal}
              canvasOpen={side === "canvas"}
              onToggleCanvas={toggleCanvas}
              onOpenCanvas={(item) => openCanvas(active.id, item)}
              onFilesChanged={(outputs) => {
                setFilesRev((n) => n + 1)
                refreshCanvas(active.id, outputs)
              }}
            />
          ) : (
            <div className="flex flex-1 flex-col items-center justify-center gap-3 p-4 font-sans text-muted-foreground">
              <p>No session selected.</p>
              <div className="flex flex-wrap justify-center gap-2">
                {(["claude_code", "codex", "kiro"] as const).map((backend) => (
                  <Button key={backend} variant="outline" onClick={() => create(backend)}>
                    <BackendIcon backend={backend} />
                    New {BACKEND_NAMES[backend]} session
                  </Button>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Kept mounted, so a page keeps its state (a video its position)
            while the terminals are shown instead. */}
        <div className={column} style={{ display: side === "canvas" ? "flex" : "none" }}>
          <Canvas
            sessionId={active?.id ?? null}
            item={active ? (canvases[active.id] ?? null) : null}
            filesRev={filesRev}
            onOpen={(item) => active && openCanvas(active.id, item)}
            narrow={narrow}
            onBack={() => setSide(null)}
            maximized={maximized}
            onToggleMaximized={toggleFull}
            treeOpen={treeOpen}
            onTreeOpen={setTreeOpen}
            walking={treeWalk}
            nav={treeNav}
            onMoved={(source, from, to) => active && followCanvas(active.id, source, from, to)}
          />
        </div>

        {side === "browser" && (
          <div className={column}>
            <Suspense fallback={null}>
              <Browser
                narrow={narrow}
                maximized={maximized}
                onToggleMaximized={toggleFull}
                onClose={() => setSide(null)}
              />
            </Suspense>
          </div>
        )}

        {appsUsed && (
          <div className={column} style={{ display: side === "apps" ? "flex" : "none" }}>
            <Apps
              apps={apps}
              narrow={narrow}
              maximized={maximized}
              onToggleMaximized={toggleFull}
              onClose={() => setSide(null)}
            />
          </div>
        )}

        {/* Kept mounted once opened: unmounting would drop the channel and
            xterm's scrollback, and the shell itself keeps running server-side
            either way. */}
        {ptyIds.length > 0 && (
          <div
            className={column}
            style={{ display: terminalOpen ? "flex" : "none" }}
          >
            {ptyIds.map((id, index) => (
              <div className="terminal-pane flex min-h-0 flex-1 basis-0 flex-col overflow-hidden border-t first:border-t-0" key={id}>
                <PaneHead
                  main={index === 0}
                  title={
                    <>
                      {/* On a phone the terminals cover the chat, and the
                          header's toggle with it. */}
                      {narrow && index === 0 && (
                        <PaneButton
                          icon={ArrowLeft01Icon}
                          onClick={() => setTerminalOpen(false)}
                          title="Back to the chat"
                        />
                      )}
                      <PaneTitle>Terminal {index + 1}</PaneTitle>
                    </>
                  }
                >
                  {/* On every pane rather than once, so they do not move
                      around as terminals are closed. */}
                  {!narrow && (
                    <PaneButton
                      icon={maximized ? Minimize01Icon : Maximize01Icon}
                      onClick={toggleFull}
                      title={maximized ? "Back beside the chat (Esc outside a shell)" : "Full window"}
                    />
                  )}
                  <PaneButton icon={PlusSignIcon} onClick={addTerminal} title="New terminal" />
                  <PaneButton icon={Cancel01Icon} onClick={() => closeTerminal(id)} title="Close this terminal" />
                </PaneHead>
                {/* Terminal positions itself absolutely, so this has to be a
                    positioning context or it escapes the pane. */}
                <div className="relative min-h-0 flex-1">
                  <Terminal sessionId={id} active={terminalOpen} />
                </div>
              </div>
            ))}
          </div>
        )}
      </main>

      {searching && (
        <Search sessions={sessions} search={search} onOpen={select} onClose={() => setSearching(false)} />
      )}
      {moving && (
        <MovePicker
          title={`Move ${sessions.find((s) => s.id === moving)?.title ?? moving} to…`}
          dirs={filed(sessions, directoryOrder)}
          current={sessions.find((s) => s.id === moving)?.directory ?? ROOT}
          onPick={(dir) => moveTo(moving, dir)}
          onClose={() => setMoving(null)}
        />
      )}
      {deleting && (
        <Confirm
          title={`Delete ${sessions.find((s) => s.id === deleting)?.title ?? deleting}?`}
          detail="The session and its whole history, with what it made. This cannot be undone."
          onYes={async () => {
            const id = deleting
            // The cursor moves on to a neighbour rather than off the list.
            if (listCursor === id) setListCursor(step(ids, id, 1) === id ? step(ids, id, -1) : step(ids, id, 1))
            await deleteAgent(id)
            drop(id)
          }}
          onClose={() => setDeleting(null)}
        />
      )}
      <ViewportReadout />
      <WhichKey pending={pending} keymap={keymap} groups={{ "Space n": "new session" }} />
      {help && (
        <KeyHelp
          keymap={keymap}
          extra={[["C-`", "terminal, from anywhere — a shell too"]]}
          onClose={() => setHelp(false)}
        />
      )}
    </SidebarProvider>
  )
}

const BACKEND_NAMES = { claude_code: "Claude Code", codex: "Codex", kiro: "Kiro" } as const

// The conversation and the column beside it, each a card beside the floating
// sidebar, as shadcn's inset layout has its content; not on a phone, where
// each has the screen to itself. Their corners stay a card's even on a touch
// screen: only the sidebar's outer side follows the display's round corners
// (ui/sidebar.tsx), as rounder cards read as too soft.
const CARD =
  " bg-background sm:overflow-hidden sm:rounded-xl sm:shadow-sm sm:ring-1 sm:ring-sidebar-border"

export default App
