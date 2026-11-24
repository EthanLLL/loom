import type RFB from "@novnc/novnc"

// noVNC's own table is not exported (the package exports rfb.js alone).
const NAMES: Record<number, string> = {
  0: "Raw", 1: "CopyRect", 2: "RRE", 5: "Hextile", 6: "Zlib", 7: "Tight", 16: "ZRLE", 21: "JPEG", 50: "H.264", [-260]: "TightPNG",
}
const encodingName = (n: number) => NAMES[n] ?? `encoding ${n}`

/** A second of a VNC screen: frames drawn, megabits received, the encoding most rects came in. */
export type VncStats = { fps: number; mbps: number; encoding: string | null }

/**
 * Measures a screen while it is shown, every second, to tell a slow screen's
 * cause apart: few frames at a high rate is the encoding, few at a low one
 * the line. Reaches into noVNC's internals (`_display.flip`, one call per
 * finished update; `_handleDataRect`, one per rect), which carry no promise
 * of staying put: if they are gone, frames and encodings read nothing.
 */
export function meter(r: RFB, channel: WebSocket | RTCDataChannel, onTick: (s: VncStats) => void): () => void {
  let frames = 0
  let bytes = 0
  const rects = new Map<number, number>()
  const inner = r as unknown as {
    _display?: { flip?: (...a: unknown[]) => unknown }
    _handleDataRect?: (...a: unknown[]) => unknown
    _FBU?: { encoding: number | null }
  }

  const display = inner._display
  const flip = display?.flip
  if (display && flip) {
    display.flip = (...a: unknown[]) => {
      frames++
      return flip.apply(display, a)
    }
  }
  const handle = inner._handleDataRect
  if (handle) {
    let seen: unknown = null
    inner._handleDataRect = (...a: unknown[]) => {
      // A rect larger than what has arrived is handled again when more does;
      // counted once.
      const fbu = inner._FBU
      if (fbu && fbu !== seen && fbu.encoding !== null) rects.set(fbu.encoding, (rects.get(fbu.encoding) ?? 0) + 1)
      const done = handle.apply(r, a)
      seen = done ? null : fbu
      return done
    }
  }

  const onMessage = (e: Event) => {
    const data = (e as MessageEvent).data
    bytes += data instanceof ArrayBuffer ? data.byteLength : data instanceof Blob ? data.size : 0
  }
  channel.addEventListener("message", onMessage)

  const timer = setInterval(() => {
    let top: number | null = null
    for (const [enc, n] of rects) if (top === null || n > rects.get(top)!) top = enc
    onTick({ fps: frames, mbps: (bytes * 8) / 1e6, encoding: top === null ? null : encodingName(top) })
    frames = 0
    bytes = 0
    rects.clear()
  }, 1000)

  return () => {
    clearInterval(timer)
    channel.removeEventListener("message", onMessage)
  }
}
