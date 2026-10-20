import { useEffect, useState } from "react"
import { deletePushSubscription, pushKey, savePushSubscription } from "./api"

/**
 * Notifications when a turn ends, per device; the server side is `Loom.Push`.
 *
 * - `unsupported`: no Push API here. On an iPhone that means Safari rather
 *   than the home-screen app, which is the only place iOS allows it.
 * - `denied`: the user said no; only the browser's settings can undo it.
 * - `off` / `on`: whether this device has a subscription.
 *
 * A device that is subscribed sends it again on every start: a browser can
 * rotate it, and the server forgets one its push service rejected.
 */
export type PushState = "unsupported" | "denied" | "off" | "on"

export type Push = {
  state: PushState
  // This device's subscription, which is how the server knows it.
  endpoint: string | null
  busy: boolean
  error: string | null
  toggle: () => void
}

const supported = () =>
  "serviceWorker" in navigator && "PushManager" in window && "Notification" in window

/** Register the worker. Harmless where push is missing; it does nothing else. */
export function registerWorker() {
  if (!("serviceWorker" in navigator)) return
  void navigator.serviceWorker.register("/sw.js").catch(() => {})
}

export function usePush(enabled: boolean): Push {
  const [state, setState] = useState<PushState>(() =>
    !supported() ? "unsupported" : Notification.permission === "denied" ? "denied" : "off",
  )
  const [endpoint, setEndpoint] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!enabled || !supported()) return
    let live = true
    void (async () => {
      const registration = await navigator.serviceWorker.ready
      const sub = await registration.pushManager.getSubscription()
      if (!live || !sub) return
      if (Notification.permission !== "granted") return
      setEndpoint(sub.endpoint)
      setState("on")
      await savePushSubscription(sub.toJSON(), false).catch(() => {})
    })()
    return () => {
      live = false
    }
  }, [enabled])

  const turnOn = async () => {
    // First, and before anything else is awaited: iOS only asks inside the
    // tap that called it.
    const permission = await Notification.requestPermission()
    if (permission !== "granted") {
      setState(permission === "denied" ? "denied" : "off")
      return
    }
    const { key } = await pushKey()
    const registration = await navigator.serviceWorker.ready
    let sub = await registration.pushManager.getSubscription()
    // Made against another key (the server's file was lost): it can never be
    // used, and subscribing again over it is refused.
    if (sub && !sameKey(sub.options.applicationServerKey, key)) {
      await sub.unsubscribe()
      sub = null
    }
    sub ??= await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: fromBase64Url(key),
    })
    await savePushSubscription(sub.toJSON(), true)
    setEndpoint(sub.endpoint)
    setState("on")
  }

  const turnOff = async () => {
    const registration = await navigator.serviceWorker.ready
    const sub = await registration.pushManager.getSubscription()
    if (sub) {
      await deletePushSubscription(sub.endpoint)
      await sub.unsubscribe()
    }
    setEndpoint(null)
    setState("off")
  }

  const toggle = () => {
    if (busy || state === "unsupported" || state === "denied") return
    setBusy(true)
    setError(null)
    ;(state === "on" ? turnOff() : turnOn())
      .catch((e: Error) => setError(e.message))
      .finally(() => setBusy(false))
  }

  return { state, endpoint, busy, error, toggle }
}

/**
 * Whether the page is in front, as the server needs to know to hold back
 * notifications for the session on screen.
 */
export function useVisible(): boolean {
  const [visible, setVisible] = useState(() => document.visibilityState === "visible")
  useEffect(() => {
    const update = () => setVisible(document.visibilityState === "visible")
    document.addEventListener("visibilitychange", update)
    return () => document.removeEventListener("visibilitychange", update)
  }, [])
  return visible
}

function fromBase64Url(text: string): Uint8Array<ArrayBuffer> {
  const base64 = text.replace(/-/g, "+").replace(/_/g, "/")
  const raw = atob(base64 + "=".repeat((4 - (base64.length % 4)) % 4))
  return Uint8Array.from(raw, (c) => c.charCodeAt(0))
}

function sameKey(current: ArrayBuffer | null, key: string): boolean {
  if (!current) return false
  const a = new Uint8Array(current)
  const b = fromBase64Url(key)
  return a.length === b.length && a.every((x, i) => x === b[i])
}
