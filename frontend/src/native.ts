import { useEffect, useRef } from "react"

/**
 * The iOS app (its own repository, loom-ios). SwiftUI owns the whole layout there
 * — the session list, every bar and button, the composer, the terminals — and
 * the page renders only what goes under the glass, in one of two web views:
 *
 * - `main` (`?surface=main`): one conversation's transcript, plus what is not
 *   worth a native copy (search, settings, sign-in). It also holds the
 *   socket, the lobby and the API for the app, which drives it through here.
 * - `pane` (`?surface=pane`): what the right-hand column shows below its
 *   glass bar, the canvas or Loom's browser.
 *
 * The app adds a script handler named `loom`; its presence is how the page
 * knows. The page tells the app what changed with `post`; the app does
 * things by dispatching `loom-native` with `{ action, value }`. Nothing about
 * where anything is on screen crosses: the app lays itself out, and tells
 * WebKit what its glass covers (`obscuredContentInsets`), which sizes the
 * page's viewport for it.
 */

type Handler = { postMessage: (message: unknown) => void }

const handler: Handler | undefined = (window as { webkit?: { messageHandlers?: { loom?: Handler } } }).webkit
  ?.messageHandlers?.loom

const asked = new URLSearchParams(location.search).get("surface")

/** Which of the app's web views this page is: it says so in the address. An
 * app from before this layout loads the plain address and gets the page as
 * a browser has it. */
export const surface: "main" | "pane" | null =
  handler !== undefined && (asked === "main" || asked === "pane") ? asked : null

/** Whether this page is inside the iOS app. */
export const native = surface !== null

if (native) {
  document.documentElement.classList.add("native", `native-${surface}`)
  // An app, not a document: no pinch zoom, which also keeps WebKit from
  // holding on to a zoom or an offset when the Duo folds or unfolds.
  const meta = document.querySelector<HTMLMetaElement>('meta[name="viewport"]')
  if (meta) meta.content += ", maximum-scale=1, user-scalable=no"
}

/** Tell the app something; nothing outside the app. */
export function post(message: Record<string, unknown>): void {
  handler?.postMessage(message)
}

/** `post` from a component whenever `message` changes. */
export function usePost(message: Record<string, unknown>, on = true): void {
  const json = JSON.stringify(message)
  useEffect(() => {
    if (on) post(JSON.parse(json))
  }, [json, on])
}

/** Tell the app the theme's colours, so what is around the page matches:
 * `background` the backdrop (the sidebar's), `page` the conversation's own. */
export function tellNativeTheme(background: string, page: string, dark: boolean): void {
  post({ theme: { background, page, dark } })
}

/** Run `run` when the app asks for `action`, with what it sent along. */
export function useNativeAction(action: string, run: (value: unknown) => void): void {
  const latest = useRef(run)
  latest.current = run
  useEffect(() => {
    if (!native) return
    const onAction = (e: Event) => {
      const detail = (e as CustomEvent<{ action: string; value?: unknown }>).detail
      if (detail?.action === action) latest.current(detail.value)
    }
    window.addEventListener("loom-native", onAction)
    return () => window.removeEventListener("loom-native", onAction)
  }, [action])
}

/** A string the app sent, or "". */
export const str = (value: unknown) => (typeof value === "string" ? value : "")

/** An object the app sent, or {}. */
export const obj = (value: unknown) =>
  value !== null && typeof value === "object" ? (value as Record<string, unknown>) : {}
