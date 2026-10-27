import { useEffect, useRef, useState } from "react"
import RFB from "@novnc/novnc"
import { ArrowRightToLine, ChevronLeft, CornerDownLeft, Delete, Keyboard, Maximize, Minimize, RefreshCw, Scan, Send, X } from "lucide-react"
import { getToken } from "./api"

/**
 * Loom's own browser — the Chromium that agents drive over CDP — shown here so
 * the user can take it over: log in to a site once, get past a check that
 * wants a human. Over VNC: `LoomWeb.VncSocket` carries it, noVNC draws it.
 *
 * Mounted only while shown, so a closed pane holds no connection open.
 */
export function Browser({
  narrow,
  maximized,
  onToggleMaximized,
  onClose,
}: {
  narrow: boolean
  maximized: boolean
  onToggleMaximized: () => void
  onClose: () => void
}) {
  const screen = useRef<HTMLDivElement>(null)
  const rfb = useRef<RFB | null>(null)
  const [state, setState] = useState<"connecting" | "connected" | "closed">("connecting")
  const [attempt, setAttempt] = useState(0)
  // Fit the whole screen in the pane, or show it at 1:1 and pan by dragging;
  // a phone wants the second to read anything.
  const [fit, setFit] = useState(!narrow)
  const [typing, setTyping] = useState(false)
  const [text, setText] = useState("")

  useEffect(() => {
    const el = screen.current
    if (!el) return
    const proto = location.protocol === "https:" ? "wss:" : "ws:"
    const url = `${proto}//${location.host}/browser/vnc?token=${encodeURIComponent(getToken() ?? "")}`
    const r = new RFB(el, url, { wsProtocols: [] })
    r.background = "transparent"
    r.addEventListener("connect", () => setState("connected"))
    r.addEventListener("disconnect", () => setState("closed"))
    rfb.current = r
    setState("connecting")
    return () => {
      rfb.current = null
      r.disconnect()
    }
  }, [attempt])

  useEffect(() => {
    const r = rfb.current
    if (!r) return
    r.scaleViewport = fit
    r.clipViewport = !fit
    r.dragViewport = !fit && narrow
  }, [fit, narrow, attempt, state])

  // A phone's keyboard won't come up for a canvas, so text goes in through a
  // field of our own and is typed into the page key by key.
  const send = (s: string) => {
    const r = rfb.current
    if (!r) return
    for (const ch of s) {
      const code = ch.codePointAt(0)!
      // X keysyms: Latin-1 is its own code point; the rest of Unicode is offset.
      r.sendKey(code < 0x100 ? code : 0x01000000 + code, null)
    }
  }
  const key = (keysym: number) => rfb.current?.sendKey(keysym, null)

  return (
    <div className="browser-pane">
      <div className="pane-head">
        <span className="pane-title">
          {narrow && (
            <button className="pane-btn" onClick={onClose} title="Back to the chat">
              <ChevronLeft />
            </button>
          )}
          browser
          {state !== "connected" && <span className="browser-state">{state === "connecting" ? "connecting…" : "disconnected"}</span>}
        </span>
        <span className="pane-actions">
          {state === "closed" && (
            <button className="pane-btn" onClick={() => setAttempt((n) => n + 1)} title="Connect again">
              <RefreshCw />
            </button>
          )}
          <button
            className={"pane-btn" + (typing ? " on" : "")}
            onClick={() => setTyping((t) => !t)}
            title="Type text into the page"
          >
            <Keyboard />
          </button>
          <button
            className="pane-btn"
            onClick={() => setFit((f) => !f)}
            title={fit ? "Actual size; drag to pan on a touch screen" : "Fit the screen in the pane"}
          >
            <Scan />
          </button>
          {!narrow && (
            <button
              className="pane-btn"
              onClick={onToggleMaximized}
              title={maximized ? "Back beside the chat" : "Full window"}
            >
              {maximized ? <Minimize /> : <Maximize />}
            </button>
          )}
          {!narrow && (
            <button className="pane-btn" onClick={onClose} title="Close">
              <X />
            </button>
          )}
        </span>
      </div>
      {typing && (
        <form
          className="browser-type"
          onSubmit={(e) => {
            e.preventDefault()
            send(text)
            setText("")
          }}
        >
          <input
            value={text}
            onChange={(e) => setText(e.target.value)}
            placeholder="Text for the focused field"
            autoCapitalize="off"
            autoCorrect="off"
            autoComplete="off"
            spellCheck={false}
          />
          <button type="submit" className="pane-btn" title="Type it">
            <Send />
          </button>
          <button type="button" className="pane-btn" onClick={() => key(0xff08)} title="Backspace">
            <Delete />
          </button>
          <button type="button" className="pane-btn" onClick={() => key(0xff09)} title="Tab">
            <ArrowRightToLine />
          </button>
          <button type="button" className="pane-btn" onClick={() => key(0xff0d)} title="Enter">
            <CornerDownLeft />
          </button>
        </form>
      )}
      <div className="browser-screen" ref={screen} />
    </div>
  )
}
