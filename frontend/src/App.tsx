import { useEffect, useRef, useState } from "react"
import { Chat } from "./Chat"
import { Login } from "./Login"
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
  getToken,
  listSessions,
  onUnauthorized,
  type AgentBackend,
} from "./api"
import { dropSocket } from "./socket"
import "./App.css"

const SIDEBAR_KEY = "loom_sidebar_open"
const TOUCH = matchMedia("(hover: none)")

function App() {
  const [authed, setAuthed] = useState(!!getToken())
  // Pushed by the server as sessions change; see `useLobby`.
  const { sessions, loaded, upsert, drop } = useLobby(authed)
  const [activeId, setActiveId] = useState<string | null>(null)
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

  const [terminalOpen, setTerminalOpen] = useState(false)
  // PTY session ids, top to bottom in the right-hand column.
  const [ptyIds, setPtyIds] = useState<string[]>([])
  const openingTerminal = useRef(false)

  // On a phone, swiping right over the chat pulls the drawer out and swiping
  // left over the drawer puts it back. Not over the terminals: a shell has its
  // own uses for a drag, and they are opened and closed by tapping.
  const chatRef = useRef<HTMLDivElement>(null)
  const drawerRef = useRef<HTMLDivElement>(null)
  useSwipe(chatRef, "right", narrow && loaded && !drawerOpen && !terminalOpen, () =>
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

  const remove = async (id: string) => {
    // A mouse has to hover to even see the button; a finger can hit it while
    // scrolling the list, and the history does not come back.
    if (TOUCH.matches && !confirm("Delete this session and its history?")) return
    await deleteAgent(id)
    drop(id)
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

  if (!authed) return <Login onSuccess={() => setAuthed(true)} />
  if (!loaded) return <div className="loading">connecting…</div>

  const active = sessions.find((s) => s.id === activeId) ?? null

  const sidebar = (
    <Sidebar
      sessions={sessions}
      activeId={activeId}
      onSelect={select}
      onCreate={create}
      onDelete={remove}
      onCollapse={() => (narrow ? setDrawerOpen(false) : setSidebarOpen(false))}
    />
  )

  return (
    <div className="app">
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
        sidebarOpen && sidebar
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

        {/* Kept mounted once opened: unmounting would drop the channel and
            xterm's scrollback, and the shell itself keeps running server-side
            either way. */}
        {ptyIds.length > 0 && (
          <div
            className="terminal-column"
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
                        ‹
                      </button>
                    )}
                    terminal {index + 1}
                  </span>
                  <span className="pane-actions">
                    {/* On every pane rather than once, so they do not move
                        around as terminals are closed. */}
                    <button
                      className="pane-btn"
                      onClick={addTerminal}
                      title="New terminal"
                    >
                      +
                    </button>
                    <button
                      className="pane-btn"
                      onClick={() => closeTerminal(id)}
                      title="Close this terminal"
                    >
                      ×
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
    </div>
  )
}

export default App
