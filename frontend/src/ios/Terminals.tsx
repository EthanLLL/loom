import { useEffect, useRef } from "react"
import type { Channel } from "phoenix"
import { createSession, deleteSession, listSessions, type Device } from "../api"
import { obj, post, str, useNativeAction } from "../native"
import { getSocket } from "../socket"

/**
 * The iOS app's terminals are its own (SwiftTerm); their bytes travel over
 * this page's socket, which already has the login. Each `terminal:<id>`
 * channel is joined while the app shows that terminal and left when it stops,
 * as `Terminal.tsx` does for xterm; the shell keeps running server-side
 * either way. Bytes cross as base64.
 *
 * A terminal may run on one of the user's devices: the list says which, and
 * which devices are online to open one on, again whenever that changes.
 */
export function NativeTerminals({ devices }: { devices: Device[] }) {
  const channels = useRef(new Map<string, Channel>())
  const online = devices.filter((d) => d.online).map((d) => d.name)
  const onlineNow = useRef(online)
  onlineNow.current = online

  const list = async () => {
    const live = await listSessions().catch(() => null)
    if (live)
      post({
        terminals: [...live].sort((a, b) => a.created_at - b.created_at).map((s) => s.id),
        terminalNodes: Object.fromEntries(live.flatMap((s) => (s.node ? [[s.id, s.node]] : []))),
        terminalDevices: onlineNow.current,
      })
  }

  const leave = (id: string) => {
    channels.current.get(id)?.leave()
    channels.current.delete(id)
  }

  useEffect(() => {
    const open = channels.current
    return () => open.forEach((channel) => channel.leave())
  }, [])

  // Up front, and again when a device comes or goes: that changes what the
  // app's "+" offers.
  const onlineKey = online.join("\n")
  useEffect(() => {
    void list()
  }, [onlineKey])

  useNativeAction("terminals", () => void list())

  // `{node}` for a device; nothing, or an app from before devices, for here.
  useNativeAction("terminal-new", async (value) => {
    const node = str(obj(value).node)
    const session = await createSession("terminal", node || undefined).catch(() => null)
    await list()
    if (session) post({ terminalCreated: session.id })
  })

  useNativeAction("terminal-open", (value) => {
    const { id, cols, rows } = obj(value)
    const name = str(id)
    if (name === "") return
    leave(name)
    const channel = getSocket().channel(`terminal:${name}`, { cols, rows })
    channel.on("output", (payload: ArrayBuffer | Uint8Array | string) => {
      const bytes =
        typeof payload === "string"
          ? new TextEncoder().encode(payload)
          : payload instanceof ArrayBuffer
            ? new Uint8Array(payload)
            : new Uint8Array(payload.buffer, payload.byteOffset, payload.byteLength)
      post({ terminal: { id: name, data: base64(bytes) } })
    })
    channel.on("closed", () => {
      leave(name)
      post({ terminalClosed: name })
      void list()
    })
    channel.join().receive("error", (resp) => post({ terminal: { id: name, error: JSON.stringify(resp) } }))
    channels.current.set(name, channel)
  })

  useNativeAction("terminal-input", (value) => {
    const { id, data } = obj(value)
    const bytes = Uint8Array.from(atob(str(data)), (c) => c.charCodeAt(0))
    channels.current.get(str(id))?.push("input", bytes.buffer)
  })

  useNativeAction("terminal-resize", (value) => {
    const { id, cols, rows } = obj(value)
    channels.current.get(str(id))?.push("resize", { cols, rows })
  })

  useNativeAction("terminal-leave", (id) => leave(str(id)))

  useNativeAction("terminal-close", async (id) => {
    leave(str(id))
    await deleteSession(str(id)).catch(() => {})
    await list()
  })

  return null
}

function base64(bytes: Uint8Array): string {
  let binary = ""
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  }
  return btoa(binary)
}
