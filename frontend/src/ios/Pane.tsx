import { lazy, Suspense, useEffect, useRef, useState } from "react"
import { moved, touches, type CanvasItem } from "../canvasItems"
import { Canvas } from "../Canvas"
import type { TreeNav } from "../FileBrowser"
import { obj, str, useNativeAction, usePost } from "../native"
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
 */
export function NativePane() {
  const [pane, setPane] = useState<"canvas" | "browser" | null>(null)
  const [sessionId, setSessionId] = useState<string | null>(null)
  const [canvases, setCanvases] = useState(loadCanvases)
  const [treeOpen, setTreeOpen] = useState(false)
  const [filesRev, setFilesRev] = useState(0)
  const nav = useRef<TreeNav | null>(null)
  const narrow = useNarrow()

  useEffect(() => localStorage.setItem(CANVAS_KEY, JSON.stringify(canvases)), [canvases])

  useNativeAction("show", (value) => {
    const { pane: p, session } = obj(value)
    setPane(p === "canvas" || p === "browser" ? p : null)
    if (str(session) !== "") setSessionId(str(session))
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
    setFilesRev((n) => n + 1)
    setCanvases((all) => {
      const item = all[str(session)]
      return item && touches(item, changed) ? { ...all, [str(session)]: { ...item, rev: Date.now() } } : all
    })
  })

  // Up, after the listeners above: the app holds its actions until this, as
  // a reload loses them.
  usePost({ ready: true })

  const open = (item: CanvasItem) => {
    if (sessionId) setCanvases((all) => ({ ...all, [sessionId]: { ...item, rev: Date.now() } }))
  }
  const follow = (source: "output" | "files", from: string, to: string | null) =>
    setCanvases((all) => {
      const item = sessionId ? all[sessionId] : undefined
      const next = item && moved(item, source, from, to)
      if (!sessionId || next === undefined) return all
      const { [sessionId]: _gone, ...rest } = all
      return next === null ? rest : { ...all, [sessionId]: { ...next, rev: Date.now() } }
    })

  return (
    <div className="flex h-dvh min-h-0 flex-col bg-background font-sans text-foreground">
      {pane === "canvas" && (
        <Canvas
          sessionId={sessionId}
          item={sessionId ? (canvases[sessionId] ?? null) : null}
          filesRev={filesRev}
          onOpen={open}
          narrow={narrow}
          onBack={() => {}}
          maximized={false}
          onToggleMaximized={() => {}}
          treeOpen={treeOpen}
          onTreeOpen={setTreeOpen}
          walking={false}
          nav={nav}
          onMoved={follow}
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
