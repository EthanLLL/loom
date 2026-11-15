import { useEffect, useRef } from "react"

/**
 * The iOS app (`ios/` in the repository): this page in a WKWebView, under the
 * app's own Liquid Glass. The app draws the conversation's top bar, the
 * sidebar's head and its new-chat button over the page, and the switches for
 * the right-hand column and the settings in its toolbar, so the page leaves
 * those out (`html.native`, App.css).
 *
 * The app adds a script handler named `loom`; its presence is how the page
 * knows. The page tells the app what to show and where (`tellNative`); the app
 * presses a button by dispatching `loom-native` with `{ action, value }`, and
 * says how much of the page its bars cover in `--native-top` and
 * `--native-bottom`.
 */

type Handler = { postMessage: (message: unknown) => void }

const handler: Handler | undefined = (window as { webkit?: { messageHandlers?: { loom?: Handler } } }).webkit
  ?.messageHandlers?.loom

/** Whether this page is inside the iOS app. */
export const native = handler !== undefined
if (native) {
  document.documentElement.classList.add("native")
  // An app, not a document: no pinch zoom, which also keeps WebKit from
  // holding on to a zoom or an offset when the Duo folds or unfolds.
  const meta = document.querySelector<HTMLMetaElement>('meta[name="viewport"]')
  if (meta) meta.content += ", maximum-scale=1, user-scalable=no"
}

export type NativeAction =
  | "terminal"
  | "canvas"
  | "apps"
  | "browser"
  | "settings"
  | "sidebar"
  | "search"
  | "new"
  | "rename"

type Rect = { x: number; y: number; w: number; h: number }

/** All the app is told, merged from the parts that know each piece. */
type NativeState = {
  // Which pane of the right-hand column is open, and how many terminals run.
  side: "terminal" | "canvas" | "browser" | "apps" | null
  terminals: number
  // The open conversation, for the top bar.
  chat: { title: string; backend: string; status: string } | null
  // Where the sidebar card (or drawer) and the chat card are, in CSS pixels;
  // null while not shown, which hides the glass that goes with each.
  sidebar: Rect | null
  card: Rect | null
}

const state: NativeState = { side: null, terminals: 0, chat: null, sidebar: null, card: null }
let posting = false

/** Change part of what the app is told; sent once per task, and only if it changed. */
export function tellNative(part: Partial<NativeState>): void {
  if (!handler) return
  let changed = false
  for (const [key, value] of Object.entries(part) as [keyof NativeState, unknown][]) {
    if (JSON.stringify(state[key]) === JSON.stringify(value)) continue
    ;(state as Record<string, unknown>)[key] = value
    changed = true
  }
  if (!changed || posting) return
  posting = true
  queueMicrotask(() => {
    posting = false
    handler.postMessage({ state })
  })
}

/** `tellNative` from a component, whenever `part` changes. */
export function useTellNative(part: Partial<NativeState>): void {
  const json = JSON.stringify(part)
  useEffect(() => tellNative(JSON.parse(json)), [json])
}

/** Tell the app the theme's background, so the bars around the page match. */
export function tellNativeTheme(background: string, dark: boolean): void {
  handler?.postMessage({ theme: { background, dark } })
}

/** Run `run` when the app presses the button for `action`. */
export function useNativeAction(action: NativeAction, run: (value: string) => void): void {
  const latest = useRef(run)
  latest.current = run
  useEffect(() => {
    if (!native) return
    const onAction = (e: Event) => {
      const detail = (e as CustomEvent<{ action: string; value?: string }>).detail
      if (detail?.action === action) latest.current(detail.value ?? "")
    }
    window.addEventListener("loom-native", onAction)
    return () => window.removeEventListener("loom-native", onAction)
  }, [action])
}

/**
 * Keep the app told where the sidebar and the chat card are. Measured again
 * for a moment after anything in `deps` changes, which covers the sidebar's
 * slide (200 ms), and on every resize.
 */
export function useNativeLayout(deps: unknown[], hideCard: boolean): void {
  const hide = useRef(hideCard)
  hide.current = hideCard
  useEffect(() => {
    if (!native) return
    let frame = 0
    let until = 0
    const measure = () => {
      tellNative({
        sidebar: rectOf(document.querySelector('[data-sidebar="sidebar"]')),
        card: hide.current ? null : rectOf(document.querySelector(".chat-card")),
      })
      frame = performance.now() < until ? requestAnimationFrame(measure) : 0
    }
    const settle = () => {
      until = performance.now() + 450
      if (!frame) frame = requestAnimationFrame(measure)
    }
    settle()
    window.addEventListener("resize", settle)
    return () => {
      window.removeEventListener("resize", settle)
      cancelAnimationFrame(frame)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, hideCard])
}

// On screen at all, or null: a collapsed sidebar is slid off to the left.
function rectOf(el: Element | null): Rect | null {
  if (!el) return null
  const r = el.getBoundingClientRect()
  if (r.width < 1 || r.height < 1 || r.right <= 1 || r.left >= innerWidth - 1) return null
  return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) }
}
