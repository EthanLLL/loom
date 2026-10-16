import { useEffect, useState } from "react"
import { canvasBase, downloadAgentOutput, downloadAgentZip } from "./api"
import type { CanvasItem } from "./canvasItems"

/**
 * The canvas: one session's output, shown in a sandboxed iframe beside the
 * chat. Pages, images, video, PDF and text all render as the browser renders
 * them; loom adds only the frame, a reload and a download.
 *
 * `sandbox` without `allow-same-origin` puts the page on an opaque origin, so
 * nothing it runs can reach loom's token or API — and the server sends the
 * same sandbox as a CSP header in case the URL is ever opened on its own.
 */
export function Canvas({
  sessionId,
  item,
  narrow,
  onBack,
}: {
  sessionId: string | null
  item: CanvasItem | null
  narrow: boolean
  onBack: () => void
}) {
  const [base, setBase] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [reloads, setReloads] = useState(0)
  const [downloading, setDownloading] = useState(false)

  useEffect(() => {
    if (!sessionId) return
    let live = true
    setBase(null)
    canvasBase(sessionId).then(
      (b) => live && setBase(b),
      (e: Error) => live && setError(e.message),
    )
    return () => {
      live = false
    }
  }, [sessionId])

  const src =
    base && item ? base + item.path.split("/").map(encodeURIComponent).join("/") : null

  const download = () => {
    if (!sessionId || !item || downloading) return
    setDownloading(true)
    const { kind, path } = item.download
    ;(kind === "dir" ? downloadAgentZip(sessionId, path) : downloadAgentOutput(sessionId, path))
      .catch((e: Error) => setError(e.message))
      .finally(() => setDownloading(false))
  }

  return (
    <div className="canvas">
      <div className="pane-head">
        <span className="pane-title">
          {narrow && (
            <button className="pane-btn" onClick={onBack} title="Back to the chat">
              ‹
            </button>
          )}
          <span className="canvas-title" title={item?.path}>
            {item ? item.title : "canvas"}
          </span>
        </span>
        {item && (
          <span className="pane-actions">
            <button className="pane-btn" onClick={() => setReloads((n) => n + 1)} title="Reload">
              ↻
            </button>
            <button
              className={"pane-btn download" + (downloading ? " busy" : "")}
              onClick={download}
              title={
                item.download.kind === "dir"
                  ? `Download ${item.download.path} as a zip`
                  : `Download ${item.download.path}`
              }
            >
              ↓
            </button>
          </span>
        )}
      </div>
      <div className="canvas-body">
        {error && <div className="canvas-note failed">{error}</div>}
        {src ? (
          <iframe
            // Remounted on reload, and when the file changes.
            key={`${src}#${reloads}`}
            src={src}
            title={item?.title}
            sandbox="allow-scripts allow-forms allow-popups allow-modals allow-downloads"
            allow="autoplay; fullscreen"
            referrerPolicy="no-referrer"
          />
        ) : (
          !error && (
            <div className="canvas-note">
              {item ? "loading…" : "Nothing open. Click a file or page in the chat to show it here."}
            </div>
          )
        )}
      </div>
    </div>
  )
}
