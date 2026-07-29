import { useEffect, useRef, useState } from "react"
import { Terminal } from "./Terminal"
import { Login } from "./Login"
import {
  createSession,
  deleteSession,
  getLayout,
  getToken,
  putLayout,
  type Layout,
  type Tab,
} from "./api"
import "./App.css"

const MAX_PANES = 3

function newTabId() {
  return "t_" + Math.random().toString(36).slice(2, 10)
}

function App() {
  const [authed, setAuthed] = useState(!!getToken())
  const [layout, setLayout] = useState<Layout>({ tabs: [], active_tab: null })
  const [loading, setLoading] = useState(true)
  const persistTimer = useRef<number | null>(null)

  // Load the saved layout (reconciled against live sessions on the server). If
  // nothing survives, start a fresh tab with one pane.
  useEffect(() => {
    if (!authed) return
    ;(async () => {
      try {
        let l = await getLayout()
        if (l.tabs.length === 0) {
          const s = await createSession()
          l = { tabs: [{ id: newTabId(), panes: [s.id] }], active_tab: null }
          l.active_tab = l.tabs[0].id
        }
        setLayout(l)
      } finally {
        setLoading(false)
      }
    })()
  }, [authed])

  // Persist layout to the backend (debounced) whenever it changes.
  useEffect(() => {
    if (loading) return
    if (persistTimer.current) window.clearTimeout(persistTimer.current)
    persistTimer.current = window.setTimeout(() => {
      putLayout(layout).catch(() => {})
    }, 150)
  }, [layout, loading])

  const setActiveTab = (id: string) =>
    setLayout((l) => ({ ...l, active_tab: id }))

  const addTab = async () => {
    const s = await createSession()
    const tab: Tab = { id: newTabId(), panes: [s.id] }
    setLayout((l) => ({ tabs: [...l.tabs, tab], active_tab: tab.id }))
  }

  const closeTab = async (tabId: string) => {
    const tab = layout.tabs.find((t) => t.id === tabId)
    if (tab) await Promise.all(tab.panes.map((p) => deleteSession(p)))

    setLayout((l) => {
      const idx = l.tabs.findIndex((t) => t.id === tabId)
      const tabs = l.tabs.filter((t) => t.id !== tabId)
      let active = l.active_tab
      if (active === tabId) {
        active = tabs[Math.max(0, idx - 1)]?.id ?? null
      }
      return { tabs, active_tab: active }
    })
  }

  // Ensure we never end up with zero tabs.
  useEffect(() => {
    if (loading) return
    if (layout.tabs.length === 0) {
      ;(async () => {
        const s = await createSession()
        const tab: Tab = { id: newTabId(), panes: [s.id] }
        setLayout({ tabs: [tab], active_tab: tab.id })
      })()
    }
  }, [layout.tabs.length, loading])

  const splitPane = async (tabId: string) => {
    const tab = layout.tabs.find((t) => t.id === tabId)
    if (!tab || tab.panes.length >= MAX_PANES) return
    const s = await createSession()
    setLayout((l) => ({
      ...l,
      tabs: l.tabs.map((t) =>
        t.id === tabId ? { ...t, panes: [...t.panes, s.id] } : t,
      ),
    }))
  }

  const closePane = async (tabId: string, sessionId: string) => {
    const tab = layout.tabs.find((t) => t.id === tabId)
    if (!tab) return

    // Closing the last pane in a tab closes the tab.
    if (tab.panes.length <= 1) {
      await closeTab(tabId)
      return
    }

    await deleteSession(sessionId)
    setLayout((l) => ({
      ...l,
      tabs: l.tabs.map((t) =>
        t.id === tabId
          ? { ...t, panes: t.panes.filter((p) => p !== sessionId) }
          : t,
      ),
    }))
  }

  if (!authed) {
    return <Login onSuccess={() => setAuthed(true)} />
  }

  if (loading) return <div className="loading">connecting…</div>

  return (
    <div className="app">
      <div className="tabbar">
        {layout.tabs.map((t, i) => (
          <div
            key={t.id}
            className={"tab" + (t.id === layout.active_tab ? " active" : "")}
            onClick={() => setActiveTab(t.id)}
          >
            <span className="tab-label">
              shell {i + 1}
              {t.panes.length > 1 ? ` (${t.panes.length})` : ""}
            </span>
            <span
              className="tab-close"
              title="Close tab"
              onClick={(e) => {
                e.stopPropagation()
                closeTab(t.id)
              }}
            >
              ×
            </span>
          </div>
        ))}
        <button className="tab new" onClick={addTab} title="New tab">
          +
        </button>
      </div>

      {/* Keep every tab mounted so its panes' terminals aren't torn down when
          switching tabs; hide the inactive ones. */}
      <div className="tabs-area">
        {layout.tabs.map((t) => (
          <div
            key={t.id}
            className="panes"
            style={{ display: t.id === layout.active_tab ? "flex" : "none" }}
          >
            {t.panes.map((sessionId) => (
              <div className="pane" key={sessionId}>
                <div className="pane-toolbar">
                  {t.panes.length < MAX_PANES && (
                    <button
                      className="pane-btn"
                      title="Split right"
                      onClick={() => splitPane(t.id)}
                    >
                      ⧉
                    </button>
                  )}
                  <button
                    className="pane-btn"
                    title="Close pane"
                    onClick={() => closePane(t.id, sessionId)}
                  >
                    ×
                  </button>
                </div>
                <Terminal
                  sessionId={sessionId}
                  active={t.id === layout.active_tab}
                />
              </div>
            ))}
          </div>
        ))}
      </div>
    </div>
  )
}

export default App
