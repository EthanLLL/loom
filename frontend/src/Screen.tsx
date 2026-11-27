import { useEffect, useRef, useState, type ReactNode } from "react"
import { ArrowLeft01Icon, Cancel01Icon, Maximize01Icon, Minimize01Icon, ReloadIcon } from "@hugeicons/core-free-icons"
import { PaneButton, PaneHead, PaneTitle } from "./Pane"
import type { VncLine } from "./Vnc"

// loom-mac-screen's messages (its Wire.swift): one byte of type, four of
// length, the payload.
const CONFIG = 1
const FRAME = 2
const ERROR = 3
const INPUT = 10
const KEYFRAME = 11
const SETTINGS = 12

/** Whether a failure means loom-mac-screen isn't on the device at all. */
const missing = (message: string) => message.includes("nothing is listening")

/**
 * A Mac's screen from loom-mac-screen: H.264 decoded by the browser
 * (WebCodecs) onto a canvas, the mouse and keys sent back as they happen.
 * The line is whatever `open` gives, direct, relayed or through loom; the
 * pane only speaks the protocol, and tells the Mac what kind of line it is,
 * which decides the picture's size and rate there. `onMissing` is told when nothing answers on the
 * device's port, for Desktop to fall back to VNC.
 *
 * Keys go as positions (KeyboardEvent.code), so the Mac's own input source
 * makes the text; the clipboard is the Mac's.
 */
export function ScreenPane({
  title,
  open,
  onMissing,
  narrow,
  maximized,
  onToggleMaximized,
  onClose,
}: {
  title: ReactNode
  open: () => Promise<VncLine>
  onMissing: () => void
  narrow: boolean
  maximized: boolean
  onToggleMaximized: () => void
  onClose: () => void
}) {
  const canvas = useRef<HTMLCanvasElement>(null)
  const [state, setState] = useState<"connecting" | "connected" | "closed">("connecting")
  const [note, setNote] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [stats, setStats] = useState<{ fps: number; mbps: number; size: string } | null>(null)
  const [attempt, setAttempt] = useState(0)
  const send = useRef<(type: number, body?: object) => void>(() => {})

  const latest = useRef({ open, onMissing })
  latest.current = { open, onMissing }

  useEffect(() => {
    const el = canvas.current
    if (!el) return
    const ctx = el.getContext("2d")!
    let gone = false
    let line: VncLine | null = null
    let channel: WebSocket | RTCDataChannel | null = null
    let decoder: VideoDecoder | null = null
    let config: VideoDecoderConfig | null = null
    let needKey = true
    let frames = 0
    let bytes = 0
    let size = ""
    setState("connecting")
    setNote(null)
    setError(null)
    setStats(null)

    const fail = (message: string) => {
      if (gone) return
      if (missing(message)) latest.current.onMissing()
      else setError(message)
      setState("closed")
    }

    const out = (type: number, body?: object) => {
      const ch = channel
      if (!ch || (ch.readyState !== "open" && ch.readyState !== WebSocket.OPEN)) return
      const payload = body ? new TextEncoder().encode(JSON.stringify(body)) : new Uint8Array()
      const m = new Uint8Array(5 + payload.length)
      m[0] = type
      new DataView(m.buffer).setUint32(1, payload.length)
      m.set(payload, 5)
      ch.send(m)
    }

    // A decoder that failed is closed for good; the next one starts from a keyframe.
    const makeDecoder = () => {
      decoder = new VideoDecoder({
        output: (frame) => {
          ctx.drawImage(frame, 0, 0, el.width, el.height)
          frame.close()
          frames++
        },
        error: () => {
          if (gone) return
          makeDecoder()
          if (config) decoder!.configure(config)
          needKey = true
          out(KEYFRAME)
        },
      })
    }
    makeDecoder()

    // Messages may come split or several to a chunk (over loom's relay, as the
    // TCP stream had them).
    let pending = new Uint8Array(0)
    const onData = (e: MessageEvent) => {
      const chunk = new Uint8Array(e.data as ArrayBuffer)
      bytes += chunk.length
      const buf = pending.length ? concat(pending, chunk) : chunk
      let at = 0
      while (buf.length - at >= 5) {
        const n = new DataView(buf.buffer, buf.byteOffset + at + 1, 4).getUint32(0)
        if (buf.length - at - 5 < n) break
        handle(buf[at], buf.subarray(at + 5, at + 5 + n))
        at += 5 + n
      }
      pending = at === buf.length ? new Uint8Array(0) : buf.slice(at)
    }

    const handle = (type: number, body: Uint8Array) => {
      if (type === CONFIG) {
        const c = JSON.parse(new TextDecoder().decode(body)) as { codec: string; width: number; height: number }
        if (config && config.codec === c.codec && config.codedWidth === c.width && config.codedHeight === c.height) return
        config = { codec: c.codec, codedWidth: c.width, codedHeight: c.height, optimizeForLatency: true, hardwareAcceleration: "prefer-hardware" }
        if (decoder!.state === "closed") makeDecoder()
        decoder!.configure(config)
        el.width = c.width
        el.height = c.height
        size = `${c.width}×${c.height}`
        needKey = true
      } else if (type === FRAME) {
        const key = (body[0] & 1) === 1
        if (decoder!.state !== "configured" || (needKey && !key)) return
        needKey = false
        const pts = Number(new DataView(body.buffer, body.byteOffset + 1, 8).getBigInt64(0))
        decoder!.decode(new EncodedVideoChunk({ type: key ? "key" : "delta", timestamp: pts, data: body.subarray(9) }))
      } else if (type === ERROR) {
        setError((JSON.parse(new TextDecoder().decode(body)) as { message: string }).message)
      }
    }

    const timer = setInterval(() => {
      if (!gone && size) setStats({ fps: frames, mbps: (bytes * 8) / 1e6, size })
      frames = 0
      bytes = 0
    }, 1000)

    void (async () => {
      try {
        line = await latest.current.open()
      } catch (e) {
        fail((e as Error).message)
        return
      }
      if (gone) {
        line.close?.()
        return
      }
      setNote(line.note ?? null)
      const ch = typeof line.channel === "string" ? new WebSocket(line.channel) : line.channel
      ch.binaryType = "arraybuffer"
      channel = ch
      const ready = () => {
        setState("connected")
        out(SETTINGS, { line: line!.kind ?? "narrow" })
        out(KEYFRAME)
      }
      if (ch.readyState === "open") ready()
      else ch.addEventListener("open", ready)
      ch.addEventListener("message", onData as EventListener)
      ch.addEventListener("close", (e) => {
        if (gone) return
        const reason = (e as CloseEvent).reason
        if (reason) fail(reason)
        else setState("closed")
      })
      send.current = out
    })()

    return () => {
      gone = true
      clearInterval(timer)
      send.current = () => {}
      channel?.close()
      line?.close?.()
      if (decoder && decoder.state !== "closed") decoder.close()
    }
  }, [attempt])


  // Where on the picture, 0…1 each way: the canvas is fitted with its
  // proportions kept, so there may be bands either side.
  const at = (e: { clientX: number; clientY: number }) => {
    const el = canvas.current!
    const r = el.getBoundingClientRect()
    const s = Math.min(r.width / el.width, r.height / el.height)
    const w = el.width * s
    const h = el.height * s
    return { x: (e.clientX - r.left - (r.width - w) / 2) / w, y: (e.clientY - r.top - (r.height - h) / 2) / h }
  }

  useEffect(() => {
    const el = canvas.current
    if (!el) return
    const input = (body: object) => send.current(INPUT, body)
    const onMove = (e: PointerEvent) => input({ t: "move", ...at(e) })
    const onDown = (e: PointerEvent) => {
      el.focus()
      el.setPointerCapture(e.pointerId)
      input({ t: "down", b: e.button, ...at(e) })
    }
    const onUp = (e: PointerEvent) => input({ t: "up", b: e.button, ...at(e) })
    const onWheel = (e: WheelEvent) => {
      e.preventDefault()
      const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 800 : 1
      input({ t: "wheel", dx: e.deltaX * k, dy: e.deltaY * k })
    }
    const onKey = (e: KeyboardEvent) => {
      e.preventDefault()
      input({ t: "key", code: e.code, down: e.type === "keydown" })
    }
    // Keys held when the focus goes would stay down on the Mac.
    const onBlur = () => input({ t: "release" })
    const noMenu = (e: Event) => e.preventDefault()
    el.addEventListener("pointermove", onMove)
    el.addEventListener("pointerdown", onDown)
    el.addEventListener("pointerup", onUp)
    el.addEventListener("wheel", onWheel, { passive: false })
    el.addEventListener("keydown", onKey)
    el.addEventListener("keyup", onKey)
    el.addEventListener("blur", onBlur)
    el.addEventListener("contextmenu", noMenu)
    return () => {
      el.removeEventListener("pointermove", onMove)
      el.removeEventListener("pointerdown", onDown)
      el.removeEventListener("pointerup", onUp)
      el.removeEventListener("wheel", onWheel)
      el.removeEventListener("keydown", onKey)
      el.removeEventListener("keyup", onKey)
      el.removeEventListener("blur", onBlur)
      el.removeEventListener("contextmenu", noMenu)
    }
  }, [])

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <PaneHead
        main
        title={
          <>
            {narrow && <PaneButton icon={ArrowLeft01Icon} onClick={onClose} title="Back to the chat" />}
            <PaneTitle>{title}</PaneTitle>
            {state === "connected" && (
              <span className="shrink-0 text-xs tabular-nums" title="frames drawn and data received in the last second">
                {[note, stats && `${stats.fps} fps`, stats && `${stats.mbps.toFixed(1)} Mbps`, stats?.size]
                  .filter(Boolean)
                  .join(" · ")}
              </span>
            )}
            {state !== "connected" && (
              <span className="shrink-0 text-xs">{state === "connecting" ? "connecting…" : "disconnected"}</span>
            )}
          </>
        }
      >
        {state === "closed" && (
          <PaneButton icon={ReloadIcon} onClick={() => setAttempt((n) => n + 1)} title="Connect again" />
        )}
        {!narrow && (
          <PaneButton
            icon={maximized ? Minimize01Icon : Maximize01Icon}
            onClick={onToggleMaximized}
            title={maximized ? "Back beside the chat" : "Full window"}
          />
        )}
        {!narrow && <PaneButton icon={Cancel01Icon} onClick={onClose} title="Close" />}
      </PaneHead>
      <div className="relative min-h-0 flex-1 bg-[#1a1a1a]">
        <canvas
          ref={canvas}
          tabIndex={0}
          className="absolute inset-0 size-full touch-none object-contain outline-none"
        />
        {error && (
          <div className="pointer-events-none absolute inset-0 flex items-center justify-center p-4 font-sans">
            <p className="max-w-sm rounded-lg bg-background px-4 py-3 text-sm text-muted-foreground shadow">{error}</p>
          </div>
        )}
      </div>
    </div>
  )
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length)
  out.set(a)
  out.set(b, a.length)
  return out
}
