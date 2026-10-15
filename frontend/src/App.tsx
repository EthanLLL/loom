import { useEffect, useRef, useState } from "react"
import { Chat } from "./Chat"
import { Login } from "./Login"
import { Sidebar } from "./Sidebar"
import { Terminal } from "./Terminal"
import { useLobby } from "./useLobby"
import { useNarrow } from "./useNarrow"
import {
  createAgent,
  createSession,
  deleteAgent,
  deleteSession,
  getToken,
  listSessions,
  type AgentBackend,
} from "./api"
import "./App.css"

const SIDEBAR_KEY = "loom_sidebar_open"
const TOUCH = matchMedia("(hover: none)")

function App() {
  const [authed, setAuthed] = useState(!!getToken())
  // Pushed by the server as sessions change; see `useLobby`.
  const { sessions, loaded, upsert, drop } = useLobby(authed)
  const [activeId, setActiveId] = useState<string | null>(null)
  const narrow = useNarrow()

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

  const toggleTerminal = async () => {
    if (terminalOpen) {
      setTerminalOpen(false)
      return
    }

    if (ptyIds.length === 0) {
      // Guarded against a double click: `ptyIds` is still empty for the second
      // call, which would spawn a second shell nobody asked for.
      if (openingTerminal.current) return
      openingTerminal.current = true

      try {
        // Adopt whatever shells are already running before starting another,
        // so a page reload reattaches instead of piling up PTYs.
        const existing = await listSessions().catch(() => [])
        const ids =
          existing.length > 0
            ? [...existing]
                .sort((a, b) => a.created_at - b.created_at)
                .map((s) => s.id)
            : [(await createSession("terminal")).id]
        setPtyIds(ids)
      } finally {
        openingTerminal.current = false
      }
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
        <div className={"drawer" + (drawerOpen ? " open" : "")} inert={!drawerOpen}>
          <div className="drawer-scrim" onClick={() => setDrawerOpen(false)} />
          {sidebar}
        </div>
      ) : (
        sidebarOpen && sidebar
      )}

      <main className="main">
        <div className="main-chat">
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
                    {/* On every pane rather than once, so it does not move
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
