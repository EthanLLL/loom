import { useEffect, useMemo, useState } from "react"
import {
  canvasBase,
  downloadAgentOutput,
  downloadAgentZip,
  downloadAttachment,
  type CanvasBases,
} from "./api"
import { viewerFor, type CanvasItem, type Viewer } from "./canvasItems"
import { Markdown } from "./markdown"

/**
 * The canvas: one session's output, shown beside the chat. Pages and PDFs go
 * in a sandboxed iframe and render as the browser renders them. Everything
 * else gets a viewer of loom's own, because a bare file in an iframe is shown
 * the way it would be in a tab of its own, and not well: an image at its full
 * size with no fit (Chrome only shrinks one to fit in a top-level tab), text
 * black on white beside a dark app, markdown as its source.
 *
 * The viewers read the file from the same signed URL the iframe would, so
 * nothing about who can see what changes. Markdown goes through the chat's own
 * renderer, which never puts model text into the DOM as markup.
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
  const [base, setBase] = useState<CanvasBases | null>(null)
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
    base && item
      ? (item.source === "files" ? base.files : base.output) +
        item.path.split("/").map(encodeURIComponent).join("/")
      : null

  const download = () => {
    if (!sessionId || !item || downloading) return
    setDownloading(true)
    const { kind, path } = item.download
    ;(kind === "dir"
      ? downloadAgentZip(sessionId, path)
      : kind === "attachment"
        ? downloadAttachment(sessionId, path)
        : downloadAgentOutput(sessionId, path))
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
        {src && item ? (
          // Remounted on reload, and when the file changes.
          <View key={`${src}#${reloads}`} src={src} item={item} />
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

function View({ src, item }: { src: string; item: CanvasItem }) {
  const viewer: Viewer = viewerFor(item.path) ?? "frame"

  switch (viewer) {
    case "image":
      return <ImageView src={src} alt={item.title} />
    case "video":
      return (
        <div className="canvas-media">
          <video src={src} controls playsInline preload="metadata" />
        </div>
      )
    case "audio":
      return (
        <div className="canvas-media">
          <audio src={src} controls preload="metadata" />
        </div>
      )
    case "markdown":
    case "table":
    case "text":
      return <TextView src={src} viewer={viewer} path={item.path} />
    case "frame":
      return (
        <iframe
          src={src}
          title={item.title}
          sandbox="allow-scripts allow-forms allow-popups allow-modals allow-downloads"
          allow="autoplay; fullscreen"
          referrerPolicy="no-referrer"
        />
      )
  }
}

/** Fitted to the pane; a click toggles its actual size, scrolled. */
function ImageView({ src, alt }: { src: string; alt: string }) {
  const [actual, setActual] = useState(false)
  return (
    <div className="canvas-media">
      <img
        src={src}
        alt={alt}
        className={actual ? "actual" : "fit"}
        onClick={() => setActual((a) => !a)}
        title={actual ? "Fit to the pane" : "Actual size"}
      />
    </div>
  )
}

// Past this, a text file is shown cut short: a multi-megabyte log rendered
// as one element would stall the page, and the download has all of it.
const TEXT_LIMIT = 1_000_000
const TABLE_ROWS = 2000

function TextView({ src, viewer, path }: { src: string; viewer: Viewer; path: string }) {
  const [text, setText] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let live = true
    fetch(src, { referrerPolicy: "no-referrer" })
      .then(async (res) => {
        if (!res.ok) throw new Error(`${res.status}`)
        return res.text()
      })
      .then(
        (t) => live && setText(t),
        (e: Error) => live && setError(`could not load: ${e.message}`),
      )
    return () => {
      live = false
    }
  }, [src])

  if (error) return <div className="canvas-note failed">{error}</div>
  if (text === null) return <div className="canvas-note">loading…</div>

  const cut = text.length > TEXT_LIMIT
  const shown = cut ? text.slice(0, TEXT_LIMIT) : text
  return (
    <div className="canvas-doc">
      {viewer === "markdown" ? (
        <Markdown text={shown} />
      ) : viewer === "table" ? (
        <Table text={shown} tsv={path.toLowerCase().endsWith(".tsv")} />
      ) : (
        <pre className="canvas-text">{pretty(shown, path)}</pre>
      )}
      {cut && <div className="canvas-note">Cut short at 1 MB. Download for the rest.</div>}
    </div>
  )
}

function pretty(text: string, path: string): string {
  if (!path.toLowerCase().endsWith(".json")) return text
  try {
    return JSON.stringify(JSON.parse(text), null, 2)
  } catch {
    return text
  }
}

function Table({ text, tsv }: { text: string; tsv: boolean }) {
  const rows = useMemo(() => {
    const rows = tsv ? text.split(/\r?\n/).map((l) => l.split("\t")) : parseCsv(text)
    while (rows.length && rows[rows.length - 1].every((c) => c === "")) rows.pop()
    return rows
  }, [text, tsv])
  if (!rows.length) return <div className="canvas-note">empty</div>

  const [head, ...body] = rows
  return (
    <div className="md-table-wrap">
      <table className="md-table canvas-table">
        <thead>
          <tr>
            {head.map((cell, i) => (
              <th key={i}>{cell}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {body.slice(0, TABLE_ROWS).map((row, r) => (
            <tr key={r}>
              {row.map((cell, c) => (
                <td key={c}>{cell}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
      {body.length > TABLE_ROWS && (
        <div className="canvas-note">
          First {TABLE_ROWS} of {body.length} rows. Download for the rest.
        </div>
      )}
    </div>
  )
}

/** RFC 4180: quoted fields may hold commas, newlines and doubled quotes. */
function parseCsv(text: string): string[][] {
  const rows: string[][] = []
  let row: string[] = []
  let field = ""
  let quoted = false
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') {
        field += '"'
        i++
      } else if (ch === '"') quoted = false
      else field += ch
    } else if (ch === '"' && field === "") quoted = true
    else if (ch === ",") {
      row.push(field)
      field = ""
    } else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++
      row.push(field)
      rows.push(row)
      row = []
      field = ""
    } else field += ch
  }
  if (field !== "" || row.length) {
    row.push(field)
    rows.push(row)
  }
  return rows
}
