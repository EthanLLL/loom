import { ChevronLeft, Maximize, Minimize, Plus, X } from "lucide-react"
import { useEffect, useRef, useState } from "react"
import { Canvas } from "./Canvas"
import { moved, touches, type CanvasItem } from "./canvasItems"
import { Confirm } from "./Confirm"
import { Chat } from "./Chat"
import type { TreeNav } from "./FileBrowser"
import { KeyHelp, useGlobalKey, useKeys, WhichKey, type Keymap } from "./keys"
import { Login } from "./Login"
import { usePush, useVisible } from "./push"
import { Sidebar } from "./Sidebar"
import { Terminal } from "./Terminal"
import { useLobby } from "./useLobby"
import { useNarrow } from "./useNarrow"
import { useSwipe } from "./useSwipe"
import {
  createAgent,
  createSession,
  deleteAgent,
  deleteSession,
  checkAuth,
  renameAgent,
  getToken,
  listSessions,
  onUnauthorized,
  type AgentBackend,
} from "./api"
import { dropSocket } from "./socket"
import "./App.css"

const SIDEBAR_KEY = "loom_sidebar_open"
const CANVAS_KEY = "loom_canvas"
const TREE_KEY = "loom_canvas_tree"
const VIM_KEY = "loom_vim"

// The right-hand side shows one thing at a time: the terminals or the canvas.
type Side = "terminal" | "canvas" | null

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
  const { sessions, devices, upsertDevice, loaded, upsert, drop } = useLobby(
    authed,
    push.endpoint ? { endpoint: push.endpoint, session: visible ? activeId : null } : null,
  )
  const narrow = useNarrow()

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

  const [side, setSide] = useState<Side>(null)
  const terminalOpen = side === "terminal"

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

  // On a phone, swiping right over the chat pulls the drawer out and swiping
  // left over the drawer puts it back. Not over the terminals: a shell has its
  // own uses for a drag, and they are opened and closed by tapping.
  const chatRef = useRef<HTMLDivElement>(null)
  const drawerRef = useRef<HTMLDivElement>(null)
  useSwipe(chatRef, "right", narrow && loaded && !drawerOpen && side === null, () =>
    setDrawerOpen(true),
  )
  useSwipe(drawerRef, "left", narrow && drawerOpen, () => setDrawerOpen(false))

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
  const create = async (backend: AgentBackend) => {
    const session = await createAgent(backend)
    upsert(session)
    setActiveId(session.id)
    setDrawerOpen(false)
  }

  const select = (id: string) => {
    setActiveId(id)
    setDrawerOpen(false)
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
      if ((e.target as Element | null)?.closest?.(".modal")) return
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
  const ids = sessions.map((s) => s.id)

  // Into the columns either side of the chat, opening them as needed: `h` and
  // `␣b` to the session list, `l` and `␣e` to the file tree.
  const toList = () => {
    setTreeWalk(false)
    setFull(false)
    setSidebarOpen(true)
    setListCursor(activeId ?? ids[0] ?? null)
  }
  const toTree = () => {
    setListCursor(null)
    setSide("canvas")
    setTreeOpen(true)
    setTreeWalk(true)
  }

  const leader: Keymap = {
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
  if (!loaded) return <div className="loading">connecting…</div>

  const active = sessions.find((s) => s.id === activeId) ?? null

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
      onCollapse={() => (narrow ? setDrawerOpen(false) : setSidebarOpen(false))}
    />
  )

  return (
    <div className={"app" + (side !== null ? " side-open" : "") + (maximized ? " maximized" : "")}>
      {narrow ? (
        // Always mounted so it can slide rather than pop. Over the chat, not
        // beside it: a phone has no width to give a second column.
        <div
          ref={drawerRef}
          className={"drawer" + (drawerOpen ? " open" : "")}
          inert={!drawerOpen}
        >
          <div className="drawer-scrim" onClick={() => setDrawerOpen(false)} />
          {sidebar}
        </div>
      ) : (
        sidebarOpen && !maximized && sidebar
      )}

      <main className="main">
        <div className="main-chat" ref={chatRef}>
          {active ? (
            // Keyed by id so switching sessions rebuilds the channel and the
            // transcript rather than mixing two conversations.
            <Chat
              key={active.id}
              session={active}
              sidebarOpen={!narrow && sidebarOpen}
              onToggleSidebar={() =>
                narrow ? setDrawerOpen(true) : setSidebarOpen((open) => !open)
              }
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
            <div className="placeholder">
              <p>No session selected.</p>
              <div className="backend-choice">
                <button
                  className="text-btn"
                  onClick={() => create("claude_code")}
                >
                  new Claude Code session
                </button>
                <button
                  className="text-btn"
                  onClick={() => create("codex")}
                >
                  new Codex session
                </button>
              </div>
            </div>
          )}
        </div>

        {/* Kept mounted, so a page keeps its state (a video its position)
            while the terminals are shown instead. */}
        <div className="side-column" style={{ display: side === "canvas" ? "flex" : "none" }}>
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

        {/* Kept mounted once opened: unmounting would drop the channel and
            xterm's scrollback, and the shell itself keeps running server-side
            either way. */}
        {ptyIds.length > 0 && (
          <div
            className="side-column terminal-column"
            style={{ display: terminalOpen ? "flex" : "none" }}
          >
            {ptyIds.map((id, index) => (
              <div className="terminal-pane" key={id}>
                <div className="pane-head">
                  <span className="pane-title">
                    {/* On a phone the terminals cover the chat, and the
                        header's toggle with it. */}
                    {narrow && index === 0 && (
                      <button
                        className="pane-btn"
                        onClick={() => setTerminalOpen(false)}
                        title="Back to the chat"
                      >
                        <ChevronLeft />
                      </button>
                    )}
                    terminal {index + 1}
                  </span>
                  <span className="pane-actions">
                    {/* On every pane rather than once, so they do not move
                        around as terminals are closed. */}
                    {!narrow && (
                      <button
                        className="pane-btn"
                        onClick={toggleFull}
                        title={maximized ? "Back beside the chat (Esc outside a shell)" : "Full window"}
                      >
                        {maximized ? <Minimize /> : <Maximize />}
                      </button>
                    )}
                    <button
                      className="pane-btn"
                      onClick={addTerminal}
                      title="New terminal"
                    >
                      <Plus />
                    </button>
                    <button
                      className="pane-btn"
                      onClick={() => closeTerminal(id)}
                      title="Close this terminal"
                    >
                      <X />
                    </button>
                  </span>
                </div>
                <div className="pane-body">
                  <Terminal sessionId={id} active={terminalOpen} />
                </div>
              </div>
            ))}
          </div>
        )}
      </main>

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
      <WhichKey pending={pending} keymap={keymap} groups={{ "Space n": "new session" }} />
      {help && (
        <KeyHelp
          keymap={keymap}
          extra={[["C-`", "terminal, from anywhere — a shell too"]]}
          onClose={() => setHelp(false)}
        />
      )}
    </div>
  )
}

export default App
