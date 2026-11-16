import { lazy, Suspense, useEffect, useRef, useState } from "react"
import {
  deleteAgentOutputOrAttachment,
  downloadAgentOutput,
  downloadAgentZip,
  downloadAttachment,
  renameAgentOutputOrAttachment,
  sessionTree,
  type TreeFile,
} from "../api"
import { itemForAttachment, itemForPath, moved, touches, type CanvasItem } from "../canvasItems"
import { Canvas } from "../Canvas"
import type { TreeNav } from "../FileBrowser"
import { obj, str, useNativeAction, usePost } from "../native"
import { setThemePref, type ThemePref } from "../theme"
import { useNarrow } from "../useNarrow"

const Browser = lazy(() => import("../Browser").then((m) => ({ default: m.Browser })))

const CANVAS_KEY = "loom_canvas"

function loadCanvases(): Record<string, CanvasItem> {
  try {
    return JSON.parse(localStorage.getItem(CANVAS_KEY) ?? "{}")
  } catch {
    return {}
  }
}

/**
 * The iOS app's second web view (`?surface=pane`, native.ts): what its
 * right-hand column shows under the glass bar — the canvas or Loom's browser.
 * The bar's buttons are the app's; they reach the pane as actions (see
 * Canvas.tsx and Browser.tsx), and the pane says what the bar should show.
 * What each session's canvas shows is kept as App.tsx keeps it, under the
 * same key, so a browser on the same device agrees.
 *
 * Every session's files are the app's own list beside the canvas: each
 * session's listed here when the app first unfolds it, as FileBrowser.tsx
 * lists them, and handed over flat with what the canvas shows; opening,
 * downloading, renaming and deleting come back as actions. The canvas shows
 * the session of the file last opened, whichever the conversation is on.
 */
export function NativePane() {
  const [pane, setPane] = useState<"canvas" | "browser" | null>(null)
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [canvases, setCanvases] = useState(loadCanvases)
  const [treeOpen, setTreeOpen] = useState(false)
  const [filesRev, setFilesRev] = useState(0)
  const nav = useRef<TreeNav | null>(null)
  const narrow = useNarrow()
  // The sessions the app has unfolded, as listed or as why they could not be.
  const [trees, setTrees] = useState<Record<string, { files: TreeFile[]; output: TreeFile[] } | { error: string }>>({})

  useEffect(() => localStorage.setItem(CANVAS_KEY, JSON.stringify(canvases)), [canvases])

  const list = (session: string) =>
    sessionTree(session).then(
      (t) => setTrees((all) => ({ ...all, [session]: t })),
      (e: Error) => setTrees((all) => ({ ...all, [session]: { error: e.message } })),
    )
  const listed = useRef(trees)
  listed.current = trees

  // Chosen in the app's Settings, which the main page keeps; this page's
  // own copy of it is in the same storage, but read only on load.
  useNativeAction("settings-theme", (value) => setThemePref(str(value) as ThemePref))

  useNativeAction("show", (value) => {
    const { pane: p, session } = obj(value)
    setPane(p === "canvas" || p === "browser" ? p : null)
    // The conversation's session, until a file of another is opened.
    if (str(session) !== "") setSessionId((current) => current ?? str(session))
  })
  // Something in the conversation asked for the canvas: a link tapped, or a
  // turn that built a page.
  useNativeAction("canvas-open", (value) => {
    const { session, item } = obj(value)
    if (str(session) === "") return
    setSessionId(str(session))
    setCanvases((all) => ({ ...all, [str(session)]: { ...(item as CanvasItem), rev: Date.now() } }))
  })
  // A turn rewrote what the canvas shows, or brought new files.
  useNativeAction("canvas-files", (value) => {
    const { session, outputs } = obj(value)
    const changed = Array.isArray(outputs) ? outputs.map(str) : []
    if (str(session) in listed.current) void list(str(session))
    if (str(session) === sessionId) setFilesRev((n) => n + 1)
    setCanvases((all) => {
      const item = all[str(session)]
      return item && touches(item, changed) ? { ...all, [str(session)]: { ...item, rev: Date.now() } } : all
    })
  })

  const shown = sessionId ? canvases[sessionId] : undefined
  usePost({
    tree: {
      sessions: trees,
      // The row to mark, as `session|section:path`.
      current: shown ? `${sessionId}|${shown.source ?? "output"}:${shown.path}` : null,
    },
  })

  const fail = (session: string) => (e: Error) => setTrees((all) => ({ ...all, [session]: { error: e.message } }))
  const where = (value: unknown) => {
    const { session, section, path } = obj(value)
    return {
      session: str(session),
      section: str(section) === "files" ? ("files" as const) : ("output" as const),
      path: str(path),
    }
  }
  const download = (session: string, section: "output" | "files", path: string, dir: boolean) =>
    (section === "files"
      ? downloadAttachment(session, path)
      : dir
        ? downloadAgentZip(session, path)
        : downloadAgentOutput(session, path)
    ).catch(fail(session))
  const open = (session: string, item: CanvasItem) => {
    setSessionId(session)
    setCanvases((all) => ({ ...all, [session]: { ...item, rev: Date.now() } }))
  }

  useNativeAction("tree-load", (value) => {
    if (str(value) !== "") void list(str(value))
  })
  // A file: shown when the canvas can, else downloaded.
  useNativeAction("tree-open", (value) => {
    const { session, section, path } = where(value)
    const name = path.split("/").pop() ?? path
    const item =
      section === "output" ? itemForPath(path) : itemForAttachment({ name, path, size: 0, content_type: "" })
    if (item) open(session, item)
    else void download(session, section, path, false)
  })
  // A directory's own page, its index.html.
  useNativeAction("tree-page", (value) => {
    const { session, path } = where(value)
    open(session, { path: `${path}/index.html`, title: path, download: { kind: "dir", path } })
  })
  useNativeAction("tree-download", (value) => {
    const { session, section, path } = where(value)
    void download(session, section, path, obj(value).dir === true)
  })
  useNativeAction("tree-rename", async (value) => {
    const { session, section, path } = where(value)
    const name = str(obj(value).name).trim()
    if (name === "") return
    try {
      const renamed = await renameAgentOutputOrAttachment(session, section, path, name)
      follow(session, section, path, renamed.path)
    } catch (e) {
      fail(session)(e as Error)
    }
    void list(session)
  })
  // The app asked first.
  useNativeAction("tree-delete", async (value) => {
    const { session, section, path } = where(value)
    try {
      await deleteAgentOutputOrAttachment(session, section, path)
      follow(session, section, path, null)
    } catch (e) {
      fail(session)(e as Error)
    }
    void list(session)
  })

  // Up, after the listeners above: the app holds its actions until this, as
  // a reload loses them.
  usePost({ ready: true })

  // What the canvas of `session` shows, after a rename or a delete there.
  const follow = (session: string, source: "output" | "files", from: string, to: string | null) =>
    setCanvases((all) => {
      const item = all[session]
      const next = item && moved(item, source, from, to)
      if (next === undefined) return all
      const { [session]: _gone, ...rest } = all
      return next === null ? rest : { ...all, [session]: { ...next, rev: Date.now() } }
    })

  return (
    <div className="flex h-dvh min-h-0 flex-col bg-background font-sans text-foreground">
      {pane === "canvas" && (
        <Canvas
          sessionId={sessionId}
          item={shown ?? null}
          filesRev={filesRev}
          onOpen={(item) => sessionId && open(sessionId, item)}
          narrow={narrow}
          onBack={() => {}}
          maximized={false}
          onToggleMaximized={() => {}}
          treeOpen={treeOpen}
          onTreeOpen={setTreeOpen}
          walking={false}
          nav={nav}
          onMoved={(source, from, to) => sessionId && follow(sessionId, source, from, to)}
          tree={false}
        />
      )}
      {pane === "browser" && (
        <Suspense fallback={null}>
          <Browser narrow={narrow} maximized={false} onToggleMaximized={() => {}} onClose={() => {}} />
        </Suspense>
      )}
    </div>
  )
}
