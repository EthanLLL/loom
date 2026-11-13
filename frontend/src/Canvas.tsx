import { ArrowLeft01Icon, Download04Icon, FolderTreeIcon, Maximize01Icon, Minimize01Icon, ReloadIcon } from "@hugeicons/core-free-icons"
import { useEffect, useMemo, useState, type ReactNode, type RefObject } from "react"
import {
  canvasBase,
  downloadAgentOutput,
  downloadAgentZip,
  downloadAttachment,
  type CanvasBases,
} from "./api"
import { viewerFor, type CanvasItem, type Viewer } from "./canvasItems"
import { FileBrowser, type TreeNav } from "./FileBrowser"
import { Markdown } from "./markdown"
import { PaneButton, PaneHead, PaneNote, PaneTitle } from "./Pane"

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
 * same sandbox as a CSP header in case the URL is ever opened on its own. A
 * PDF is the exception, on both sides: Chrome refuses to show one sandboxed.
 *
 * The session's file tree sits on the left, beside what it opened, the way
 * NERDTree sits beside a buffer. The button at the head's left end folds it
 * away; whether it is shown is remembered across sessions and reloads. On a
 * phone there is no room for both, so the tree covers the view while it is
 * open and folds itself once something is picked.
 */
export function Canvas({
  sessionId,
  item,
  filesRev,
  onOpen,
  narrow,
  onBack,
  maximized,
  onToggleMaximized,
  treeOpen,
  onTreeOpen,
  walking,
  nav,
  onMoved,
}: {
  sessionId: string | null
  item: CanvasItem | null
  // Moves when the session's files may have changed; see `FileBrowser`.
  filesRev: number
  onOpen: (item: CanvasItem) => void
  narrow: boolean
  onBack: () => void
  maximized: boolean
  onToggleMaximized: () => void
  // Desktop only, and kept by the app, which has a key for it.
  treeOpen: boolean
  onTreeOpen: (open: boolean) => void
  // The tree walked from the keyboard; see `FileBrowser`.
  walking: boolean
  nav: RefObject<TreeNav | null>
  // A file renamed or deleted from the tree; see `FileBrowser`.
  onMoved: (source: "output" | "files", from: string, to: string | null) => void
}) {
  const [base, setBase] = useState<CanvasBases | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [reloads, setReloads] = useState(0)
  const [downloading, setDownloading] = useState(false)
  // On a phone the tree covers the view, so it starts folded when there is
  // something to see, and folds again when something is picked.
  const [phoneTree, setPhoneTree] = useState(false)
  const showTree = narrow ? phoneTree || !item : treeOpen
  const toggleTree = () => (narrow ? setPhoneTree(!showTree) : onTreeOpen(!treeOpen))

  const itemKey = item ? `${item.source ?? "output"}:${item.path}` : null
  const pick = (picked: CanvasItem) => {
    onOpen(picked)
    setPhoneTree(false)
  }

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
    <div className="flex min-h-0 flex-1 flex-col">
      <PaneHead
        main
        title={
          <>
            {narrow && <PaneButton icon={ArrowLeft01Icon} onClick={onBack} title="Back to the chat" />}
            {sessionId && (
              <PaneButton
                icon={FolderTreeIcon}
                pressed={showTree}
                onClick={toggleTree}
                title={showTree ? "Hide the files" : "All files in this session"}
              />
            )}
            <PaneTitle hint={item?.path}>{item ? item.title : "Canvas"}</PaneTitle>
          </>
        }
      >
        {item && (
          <>
            {!narrow && (
              <PaneButton
                icon={maximized ? Minimize01Icon : Maximize01Icon}
                onClick={onToggleMaximized}
                title={maximized ? "Back beside the chat (Esc)" : "Full window"}
              />
            )}
            <PaneButton icon={ReloadIcon} onClick={() => setReloads((n) => n + 1)} title="Reload" />
            <PaneButton
              icon={Download04Icon}
              onClick={download}
              disabled={downloading}
              className="disabled:cursor-progress"
              title={
                item.download.kind === "dir"
                  ? `Download ${item.download.path} as a zip`
                  : `Download ${item.download.path}`
              }
            />
          </>
        )}
      </PaneHead>
      <div className="relative flex min-h-0 flex-1">
        {/* Kept mounted while folded, so what was unfolded stays unfolded. A
            phone has no room for both: there the tree covers the view. */}
        {sessionId && (
          <div
            className={
              "min-w-0 " + (narrow ? "absolute inset-0 z-2 bg-background" : "relative w-64 shrink-0 border-r")
            }
            style={{ display: showTree ? undefined : "none" }}
          >
            <FileBrowser
              sessionId={sessionId}
              rev={filesRev}
              current={itemKey}
              onOpen={pick}
              walking={walking && showTree}
              nav={nav}
              onMoved={onMoved}
            />
          </div>
        )}
        <div className="relative min-w-0 flex-1">
          {error && <PaneNote failed>{error}</PaneNote>}
          {src && item ? (
            // Remounted on reload, when another file is opened, and when this
            // one is opened again or rewritten (`rev`).
            <View key={`${src}#${reloads}#${item.rev ?? 0}`} src={src} item={item} />
          ) : (
            !error && (
              <PaneNote>
                {item ? "Loading…" : sessionId ? "Pick a file to show it here." : "No session selected."}
              </PaneNote>
            )
          )}
        </div>
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
        <Media>
          <video src={src} controls playsInline preload="metadata" className="max-h-full max-w-full object-contain" />
        </Media>
      )
    case "audio":
      return (
        <Media>
          <audio src={src} controls preload="metadata" className="w-[min(32rem,90%)]" />
        </Media>
      )
    case "markdown":
    case "table":
    case "text":
      return <TextView src={src} viewer={viewer} path={item.path} />
    case "frame":
      // Chrome will not start its PDF viewer in a sandboxed frame. A PDF needs
      // none: the viewer is the browser's own, and the server's `nosniff`
      // keeps a `.pdf` that is really HTML from running as a page.
      return (
        <iframe
          src={src}
          title={item.title}
          sandbox={
            /\.pdf$/i.test(item.path)
              ? undefined
              : "allow-scripts allow-forms allow-popups allow-modals allow-downloads"
          }
          allow="autoplay; fullscreen"
          // White, not the app's background: pages, PDFs and plain text are
          // written to be read on white, and a transparent page would
          // otherwise be dark on dark.
          className="absolute inset-0 size-full border-0 bg-white"
          referrerPolicy="no-referrer"
        />
      )
  }
}

/** Images and media: centred by margin rather than by the flexbox, so that an
 * image at its actual size still scrolls to its top-left corner. */
function Media({ children }: { children: ReactNode }) {
  return <div className="absolute inset-0 flex overflow-auto bg-background *:m-auto">{children}</div>
}

// Behind an image, so a transparent PNG or a black-line SVG shows.
const CHECKER = "repeating-conic-gradient(#e8e8e8 0 25%, #fff 0 50%) 0 0 / 16px 16px"

/** Fitted to the pane; a click toggles its actual size, scrolled. */
function ImageView({ src, alt }: { src: string; alt: string }) {
  const [actual, setActual] = useState(false)
  return (
    <Media>
      <img
        src={src}
        alt={alt}
        style={{ background: CHECKER }}
        className={"block " + (actual ? "cursor-zoom-out" : "max-h-full max-w-full cursor-zoom-in object-contain")}
        onClick={() => setActual((a) => !a)}
        title={actual ? "Fit to the pane" : "Actual size"}
      />
    </Media>
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

  if (error) return <PaneNote failed>{error}</PaneNote>
  if (text === null) return <PaneNote>Loading…</PaneNote>

  const cut = text.length > TEXT_LIMIT
  const shown = cut ? text.slice(0, TEXT_LIMIT) : text
  return (
    // Markdown, tables and text, in the app's own colours and type.
    <div className="absolute inset-0 overflow-auto px-5 pt-4 pb-8 font-sans">
      {viewer === "markdown" ? (
        <div className="mx-auto max-w-[52rem]">
          <Markdown text={shown} />
        </div>
      ) : viewer === "table" ? (
        <Table text={shown} tsv={path.toLowerCase().endsWith(".tsv")} />
      ) : (
        <pre className="m-0 font-mono text-[0.8rem] leading-normal wrap-anywhere whitespace-pre-wrap">
          {pretty(shown, path)}
        </pre>
      )}
      {cut && <PaneNote>Cut short at 1 MB. Download for the rest.</PaneNote>}
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
  if (!rows.length) return <PaneNote>Empty.</PaneNote>

  const [head, ...body] = rows
  return (
    // The canvas itself scrolls a wide table, so its header can stick.
    <div>
      <table className="border-collapse text-sm [&_td]:border [&_td]:px-2.5 [&_td]:py-1 [&_td]:align-top [&_th]:sticky [&_th]:-top-4 [&_th]:border [&_th]:bg-muted [&_th]:px-2.5 [&_th]:py-1 [&_th]:text-left [&_th]:font-medium [&_th]:whitespace-nowrap [&_th]:text-muted-foreground">
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
        <PaneNote>
          First {TABLE_ROWS} of {body.length} rows. Download for the rest.
        </PaneNote>
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
