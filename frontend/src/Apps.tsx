import { ExternalLink, PanelLeftOpen, X } from "lucide-react"
import { useState } from "react"
import type { AppInfo } from "./api"
import "./Apps.css"

/**
 * The apps (`Loom.Apps`) as a home screen: a grid of icons in the user's
 * order that scrolls down when there are many, and one picked opens full size
 * in the main pane. The list is the lobby's, so an app an agent just made
 * appears without a reload. Each page is on the apps' own origin (Caddy,
 * see `Loom.Apps`), which is the isolation, so the frame keeps it —
 * the page gets its cookie and storage — and the page can be opened in a tab
 * of its own, which is where a browser offers to install it.
 */

const SANDBOX =
  "allow-scripts allow-forms allow-popups allow-modals allow-downloads allow-same-origin"
export function Apps({
  apps,
  sidebarOpen,
  onToggleSidebar,
}: {
  apps: AppInfo[]
  sidebarOpen: boolean
  onToggleSidebar: () => void
}) {
  const [open, setOpen] = useState<AppInfo | null>(null)

  const sidebarButton = !sidebarOpen && (
    <button className="icon-btn" onClick={onToggleSidebar} title="Show sidebar">
      <PanelLeftOpen />
    </button>
  )

  if (open) {
    return (
      <div className="apps">
        <header className="chat-header">
          <div className="chat-title">
            {sidebarButton}
            <span className="chat-name">{open.title}</span>
          </div>
          <div className="app-actions">
            <a
              className="pane-btn"
              href={open.url}
              target="_blank"
              rel="noopener"
              title="Open in its own tab"
            >
              <ExternalLink />
            </a>
            <button className="pane-btn" onClick={() => setOpen(null)} title="Back to apps">
              <X />
            </button>
          </div>
        </header>
        <iframe
          className="app-frame"
          src={open.url}
          title={open.title}
          sandbox={SANDBOX}
        />
      </div>
    )
  }

  return (
    <div className="apps">
      {sidebarButton && <div className="apps-head">{sidebarButton}</div>}
      <div className="apps-grid">
        {apps.length === 0 && <p className="apps-note">No apps yet. Ask an agent to make one.</p>}
        {apps.map((app) => (
          <button key={app.name} className="app-tile" onClick={() => setOpen(app)} title={app.name}>
            {app.icon ? (
              <img className="app-icon" src={app.icon} alt="" />
            ) : (
              <span className="app-icon app-icon-letter">{app.title.slice(0, 1).toUpperCase()}</span>
            )}
            <span className="app-label">{app.title}</span>
          </button>
        ))}
      </div>
    </div>
  )
}
