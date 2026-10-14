import { useEffect, useRef } from "react"
import { Terminal as Xterm } from "@xterm/xterm"
import { FitAddon } from "@xterm/addon-fit"
import { Unicode11Addon } from "@xterm/addon-unicode11"
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

// Nerd Font first (bundled, has the icon glyphs), then the OS emoji fonts as a
// fallback for standard emoji the Nerd Font doesn't include (e.g. ⏸ ⚠). These
// emoji fonts aren't bundled — the browser uses whichever the user's OS has
// (Apple Color Emoji on macOS, Segoe UI Emoji on Windows, Noto on Linux) —
// which is why the native terminal never showed tofu but xterm did.
const FONT =
  "'MesloLGL Nerd Font Mono', Menlo, Monaco, 'Courier New', " +
  "'Apple Color Emoji', 'Segoe UI Emoji', 'Noto Color Emoji', monospace"

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

    // Use the Unicode 11 width table so xterm's idea of how many columns a
    // glyph occupies matches what modern TUIs (Claude Code) assume. Ambiguous-
    // width symbols like U+23F8 ⏸ / U+26A0 ⚠ otherwise render at a different
    // width than the app expects, shifting the rest of the line and breaking
    // table/rule alignment.
    const unicode11 = new Unicode11Addon()
    term.loadAddon(unicode11)
    term.unicode.activeVersion = "11"

    term.open(el)
    termRef.current = term
    fitRef.current = fit

    const dec = new TextDecoder()
    const enc = new TextEncoder()

    // A channel we join lazily, only once we know the real terminal size, so
    // the shell (and any TUI like Claude Code started in it) sees the correct
    // column count from its very first output. Joining with the wrong size and
    // resizing after the fact leaves already-wrapped output mis-laid-out.
    let channel: ReturnType<ReturnType<typeof getSocket>["channel"]> | null =
      null
    let lastCols = 0
    let lastRows = 0

    // Debounced full repaint to clear ghost rows left by high-frequency
    // partial redraws (streaming tables). Fires ~80ms after output stops.
    let refreshTimer = 0
    const scheduleRefresh = () => {
      window.clearTimeout(refreshTimer)
      refreshTimer = window.setTimeout(() => {
        term.refresh(0, term.rows - 1)
      }, 80)
    }

    const joinWithSize = () => {
      fit.fit()
      lastCols = term.cols
      lastRows = term.rows

      channel = getSocket().channel(`terminal:${sessionId}`, {
        cols: term.cols,
        rows: term.rows,
      })

      channel.on("output", (payload: ArrayBuffer | Uint8Array | string) => {
        if (payload instanceof ArrayBuffer) {
          term.write(dec.decode(new Uint8Array(payload)))
        } else if (ArrayBuffer.isView(payload)) {
          term.write(dec.decode(payload as Uint8Array))
        } else if (typeof payload === "string") {
          term.write(payload)
        }
        // A TUI streaming a table repaints the same region many times per
        // second; the DOM renderer can leave ghost rows from earlier frames
        // that only a full repaint clears — which is why a manual resize fixes
        // it. Debounce a forced full refresh to the end of each output burst so
        // it self-cleans without user action.
        scheduleRefresh()
      })

      channel
        .join()
        .receive("error", (resp) =>
          term.write(`\r\n[join error] ${JSON.stringify(resp)}\r\n`),
        )
    }

    // `onData` fires for real keystrokes AND for replies xterm.js auto-generates
    // to device queries. In fullscreen, Claude Code enables newer private modes
    // (focus reporting ?1004, theme-change ?2031, synchronized output ?2026) and
    // xterm emits a private-mode report reply `ESC [ ? … R` that loops back into
    // the PTY and re-triggers itself — an infinite flood (costly over a remote
    // link). CC issues no matching query, so dropping these `?…R` reports breaks
    // the loop without swallowing anything CC is waiting on. Real user input
    // never matches this pattern.
    const REPORT_REPLY = /^\x1b\[\?[\d;]*R$/
    const onData = term.onData((data) => {
      if (REPORT_REPLY.test(data)) return
      channel?.push("input", enc.encode(data).buffer)
    })

    // Joining with the wrong column count makes a TUI (Claude Code) lay out its
    // first screen wrong, and a later resize can't re-wrap already-emitted
    // lines. The container's pixel size isn't final the instant we mount (flex
    // layout for split panes, hidden→visible tabs, fonts loading), and a
    // one-shot fit() can measure a transient width (e.g. full-width 254 cols
    // before a split pane settles to half).
    //
    // So we drive everything off the ResizeObserver + a debounce: on each size
    // change we (re)start a short timer; only when the size has been quiet for
    // ~120ms do we act. The first time, that action is the JOIN (carrying the
    // now-settled size); afterwards it's a resize. A hidden pane has zero size
    // and simply never triggers until it becomes visible.
    let joined = false
    let fontReady = false
    let debounce = 0

    const settle = () => {
      fit.fit()
      if (term.cols === lastCols && term.rows === lastRows && joined) return
      lastCols = term.cols
      lastRows = term.rows

      if (!joined) {
        joined = true
        joinWithSize()
        if (active) term.focus()
      } else if (channel) {
        channel.push("resize", { cols: term.cols, rows: term.rows })
      }
    }

    // Last box we actually acted on, so a callback for an unchanged size can
    // be dropped. ResizeObserver fires for reflows that leave this element the
    // same size, and `fit()` is not free when that happens: it resizes the
    // terminal, which reflows its content, which can bring the observer
    // straight back here. With two panes sharing a column that showed up as
    // continuous flicker after the sidebar was toggled.
    let lastWidth = 0
    let lastHeight = 0

    const onSizeChanged = () => {
      // Ignore until the font is loaded (char metrics wrong) and while the
      // container is zero-sized (hidden pane).
      if (!fontReady || el.clientWidth === 0 || el.clientHeight === 0) return
      if (el.clientWidth === lastWidth && el.clientHeight === lastHeight) return

      lastWidth = el.clientWidth
      lastHeight = el.clientHeight
      window.clearTimeout(debounce)
      debounce = window.setTimeout(settle, 120)
    }

    const observer = new ResizeObserver(onSizeChanged)
    observer.observe(el)

    // Load the Nerd Font before any measurement so glyph metrics are correct,
    // then kick an initial size check. Nothing is sent to the shell before the
    // debounced JOIN fires.
    const ready = document.fonts
      ? document.fonts.load(`14px ${FONT}`).then(() => document.fonts.ready)
      : Promise.resolve()
    ready.then(() => {
      fontReady = true
      onSizeChanged()
    })

    return () => {
      window.clearTimeout(debounce)
      window.clearTimeout(refreshTimer)
      observer.disconnect()
      onData.dispose()
      channel?.leave()
      // Do NOT disconnect the shared socket — other tabs use it.
      term.dispose()
      termRef.current = null
      fitRef.current = null
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessionId])

  // Becoming active takes the pane from display:none (zero size) to visible;
  // the ResizeObserver picks that up and re-fits. Here we only restore focus.
  useEffect(() => {
    if (!active) return
    requestAnimationFrame(() => termRef.current?.focus())
  }, [active])

  return (
    <div
      ref={containerRef}
      className="terminal-container"
      style={{ display: active ? "block" : "none" }}
    />
  )
}
