import { useEffect, useRef } from "react"
import { Terminal as Xterm } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import "@xterm/xterm/css/xterm.css"
import { getSocket } from "./socket"

// Mirrors the local iTerm2 "Default" profile palette so index-colored output
// (prompts, ls, TUIs) renders identically in the browser.
const THEME = {
  background: "#010c18",
  foreground: "#ecdef4",
  cursor: "#38ff9d",
  cursorAccent: "#010c18",
  selectionBackground: "#38ff9c",
  black: "#0b3b61",
  red: "#ff3a3a",
  green: "#52ffd0",
  yellow: "#fff383",
  blue: "#1376f9",
  magenta: "#c792ea",
  cyan: "#ff5ed4",
  white: "#16fda2",
  brightBlack: "#63686d",
  brightRed: "#ff54b0",
  brightGreen: "#74ffd8",
  brightYellow: "#fcf5ae",
  brightBlue: "#388eff",
  brightMagenta: "#ae81ff",
  brightCyan: "#ff6ad7",
  brightWhite: "#60fbbf",
}

const FONT =
  "'MesloLGL Nerd Font Mono', Menlo, Monaco, 'Courier New', monospace"

type Props = {
  sessionId: string
  active: boolean
}

export function Terminal({ sessionId, active }: Props) {
  const containerRef = useRef<HTMLDivElement>(null)
  const fitRef = useRef<FitAddon | null>(null)
  const termRef = useRef<Xterm | null>(null)

  useEffect(() => {
    const el = containerRef.current
    if (!el) return

    const term = new Xterm({
      fontFamily: FONT,
      fontSize: 14,
      cursorBlink: true,
      allowProposedApi: true,
      theme: THEME,
    })
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(el)
    termRef.current = term
    fitRef.current = fit

    const dec = new TextDecoder()
    const enc = new TextEncoder()

    const channel = getSocket().channel(`terminal:${sessionId}`, {})

    channel.on("output", (payload: ArrayBuffer | Uint8Array | string) => {
      if (payload instanceof ArrayBuffer) {
        term.write(dec.decode(new Uint8Array(payload)))
      } else if (ArrayBuffer.isView(payload)) {
        term.write(dec.decode(payload as Uint8Array))
      } else if (typeof payload === "string") {
        term.write(payload)
      }
    })

    let lastCols = 0
    let lastRows = 0
    const sendResize = () => {
      fit.fit()
      if (term.cols !== lastCols || term.rows !== lastRows) {
        lastCols = term.cols
        lastRows = term.rows
        channel.push("resize", { cols: term.cols, rows: term.rows })
      }
    }

    channel
      .join()
      .receive("error", (resp) =>
        term.write(`\r\n[join error] ${JSON.stringify(resp)}\r\n`),
      )

    const onData = term.onData((data) =>
      channel.push("input", enc.encode(data).buffer),
    )

    // Load the Nerd Font before the first fit so glyph metrics are correct.
    const ready = document.fonts
      ? document.fonts.load(`14px ${FONT}`).then(() => document.fonts.ready)
      : Promise.resolve()
    ready.then(() =>
      requestAnimationFrame(() => {
        sendResize()
        if (active) term.focus()
      }),
    )

    const observer = new ResizeObserver(() => sendResize())
    observer.observe(el)

    return () => {
      observer.disconnect()
      onData.dispose()
      channel.leave()
      // Do NOT disconnect the shared socket — other tabs use it.
      term.dispose()
      termRef.current = null
      fitRef.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId])

  // When this tab becomes active it was display:none (zero-sized) before, so
  // re-fit to the now-visible container and focus it.
  useEffect(() => {
    if (!active) return
    requestAnimationFrame(() => {
      fitRef.current?.fit()
      termRef.current?.focus()
    })
  }, [active])

  return (
    <div
      ref={containerRef}
      className="terminal-container"
      style={{ display: active ? "block" : "none" }}
    />
  )
}
