import { useCallback, useEffect, useRef, useState } from "react"
import { Chat } from "./Chat"
import { Login } from "./Login"
import { Sidebar } from "./Sidebar"
import { Terminal } from "./Terminal"
import {
  createAgent,
  createSession,
  deleteAgent,
  deleteSession,
  getToken,
  listAgents,
  listSessions,
  type AgentBackend,
  type AgentInfo,
} from "./api"
import "./App.css"

// The session list carries each agent's status and auto-generated title, and
// both change while the server works. Polling is enough here (single tenant,
// one list) and it is paused while the tab is hidden so a phone in a pocket
// is not asking every few seconds.
const POLL_MS = 5000

const SIDEBAR_KEY = "loom_sidebar_open"

function App() {
  const [authed, setAuthed] = useState(!!getToken())
  const [sessions, setSessions] = useState<AgentInfo[]>([])
  const [activeId, setActiveId] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  // Remembered, because on a narrow screen you collapse it once and want it
  // to stay collapsed across reloads.
  const [sidebarOpen, setSidebarOpen] = useState(
    () => localStorage.getItem(SIDEBAR_KEY) !== "0",
  )

  const [terminalOpen, setTerminalOpen] = useState(false)
  // PTY session ids, top to bottom in the right-hand column.
  const [ptyIds, setPtyIds] = useState<string[]>([])
  const openingTerminal = useRef(false)

  useEffect(() => {
    localStorage.setItem(SIDEBAR_KEY, sidebarOpen ? "1" : "0")
  }, [sidebarOpen])

  const refresh = useCallback(async () => {
    const list = await listAgents()
    setSessions(list)
    return list
  }, [])

  useEffect(() => {
    if (!authed) return
    ;(async () => {
      try {
        const list = await refresh()
        setActiveId((current) => current ?? list[0]?.id ?? null)
      } finally {
        setLoading(false)
      }
    })()
  }, [authed, refresh])

  useEffect(() => {
    if (!authed) return
    let timer = 0

    const tick = () => {
      if (!document.hidden) refresh().catch(() => {})
      timer = window.setTimeout(tick, POLL_MS)
    }
    timer = window.setTimeout(tick, POLL_MS)

    // Catch up immediately when the tab comes back rather than waiting out the
    // interval — on a phone that is the moment the user is looking at it.
    const onVisible = () => {
      if (!document.hidden) refresh().catch(() => {})
    }
    document.addEventListener("visibilitychange", onVisible)

    return () => {
      window.clearTimeout(timer)
      document.removeEventListener("visibilitychange", onVisible)
    }
  }, [authed, refresh])

  // The backend is chosen here and never again: the conversation lives in that
  // engine's own store, so there is nothing to migrate if it changes.
  const create = async (backend: AgentBackend) => {
    const session = await createAgent(backend)
    setSessions((list) => [...list, session])
    setActiveId(session.id)
  }

  const remove = async (id: string) => {
    await deleteAgent(id)
    const list = await refresh()
    setActiveId((current) => (current === id ? (list[0]?.id ?? null) : current))
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
  if (loading) return <div className="loading">connecting…</div>

  const active = sessions.find((s) => s.id === activeId) ?? null

  return (
    <div className="app">
      {sidebarOpen && (
        <Sidebar
          sessions={sessions}
          activeId={activeId}
          onSelect={setActiveId}
          onCreate={create}
          onDelete={remove}
          onCollapse={() => setSidebarOpen(false)}
        />
      )}

      <main className="main">
        <div className="main-chat">
          {active ? (
            // Keyed by id so switching sessions rebuilds the channel and the
            // transcript rather than mixing two conversations.
            <Chat
              key={active.id}
              session={active}
              sidebarOpen={sidebarOpen}
              onToggleSidebar={() => setSidebarOpen((open) => !open)}
              terminalOpen={terminalOpen}
              terminalCount={ptyIds.length}
              onToggleTerminal={toggleTerminal}
            />
          ) : (
            <div className="placeholder">
              <p>No session selected.</p>
              <div className="backend-choice">
                <button
                  className="composer-btn send"
                  onClick={() => create("claude_code")}
                >
                  new Claude Code session
                </button>
                <button
                  className="composer-btn send"
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
                  <span>terminal {index + 1}</span>
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
