import { useEffect, useRef, useState } from "react"
import RFB from "@novnc/novnc"
import { ArrowLeft01Icon, ArrowRightToLineIcon, ArrowTurnBackwardIcon, Cancel01Icon, DeletePutBackIcon, KeyboardIcon, Maximize01Icon, Minimize01Icon, ReloadIcon, SentIcon, ZoomInAreaIcon, ZoomOutAreaIcon } from "@hugeicons/core-free-icons"
import { Input } from "@/components/ui/input"
import { getToken } from "./api"
import { PaneButton, PaneHead, PaneTitle } from "./Pane"

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
  const catcher = useRef<HTMLTextAreaElement>(null)
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

  // Paste from this device's clipboard into the page. noVNC swallows every key
  // on its canvas, ⌘V and Ctrl+V included, so no paste event would fire: catch
  // the shortcut first and move focus to a hidden field, where the browser's
  // own paste lands, and type the text in. Not through the remote clipboard:
  // the remote Chromium reads x11vnc's clipboard once and pastes that from
  // then on. The ⌘ or Ctrl already went through and is held on the remote
  // end; noVNC lets go of every key it holds when the window loses focus, so
  // tell it the window did.
  useEffect(() => {
    const el = screen.current
    if (!el) return
    const onKey = (e: KeyboardEvent) => {
      if (e.code !== "KeyV" || !(e.metaKey || e.ctrlKey) || e.altKey || e.shiftKey) return
      e.stopPropagation()
      window.dispatchEvent(new Event("blur"))
      catcher.current?.focus()
      // The paste, if there is one, has landed by now; give the keys back.
      setTimeout(() => rfb.current?.focus())
    }
    el.addEventListener("keydown", onKey, true)
    return () => el.removeEventListener("keydown", onKey, true)
  }, [])

  const paste = (e: React.ClipboardEvent) => {
    e.preventDefault()
    const lines = e.clipboardData.getData("text/plain").replace(/\r\n?/g, "\n").split("\n")
    lines.forEach((line, i) => {
      if (i > 0) key(0xff0d)
      send(line.replaceAll("\t", " "))
    })
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <PaneHead
        main
        title={
          <>
            {narrow && <PaneButton icon={ArrowLeft01Icon} onClick={onClose} title="Back to the chat" />}
            <PaneTitle>Browser</PaneTitle>
            {state !== "connected" && (
              <span className="shrink-0 text-xs">{state === "connecting" ? "connecting…" : "disconnected"}</span>
            )}
          </>
        }
      >
        {state === "closed" && (
          <PaneButton icon={ReloadIcon} onClick={() => setAttempt((n) => n + 1)} title="Connect again" />
        )}
        <PaneButton
          icon={KeyboardIcon}
          pressed={typing}
          onClick={() => setTyping((t) => !t)}
          title="Type text into the page"
        />
        <PaneButton
          icon={fit ? ZoomInAreaIcon : ZoomOutAreaIcon}
          onClick={() => setFit((f) => !f)}
          title={fit ? "Actual size; drag to pan on a touch screen" : "Fit the screen in the pane"}
        />
        {!narrow && (
          <PaneButton
            icon={maximized ? Minimize01Icon : Maximize01Icon}
            onClick={onToggleMaximized}
            title={maximized ? "Back beside the chat" : "Full window"}
          />
        )}
        {!narrow && <PaneButton icon={Cancel01Icon} onClick={onClose} title="Close" />}
      </PaneHead>
      {typing && (
        <form
          className="flex items-center gap-1 border-b px-2 py-1.5 font-sans"
          onSubmit={(e) => {
            e.preventDefault()
            send(text)
            setText("")
          }}
        >
          {/* 16px everywhere: iOS zooms the page into any smaller field. */}
          <Input
            value={text}
            onChange={(e) => setText(e.target.value)}
            placeholder="Text for the focused field"
            className="flex-1 text-base! pointer-coarse:h-[44px]"
            autoCapitalize="off"
            autoCorrect="off"
            autoComplete="off"
            spellCheck={false}
          />
          <PaneButton type="submit" icon={SentIcon} title="Type it" />
          <PaneButton icon={DeletePutBackIcon} onClick={() => key(0xff08)} title="Backspace" />
          <PaneButton icon={ArrowRightToLineIcon} onClick={() => key(0xff09)} title="Tab" />
          <PaneButton icon={ArrowTurnBackwardIcon} onClick={() => key(0xff0d)} title="Enter" />
        </form>
      )}
      <div className="min-h-0 flex-1 bg-[#1a1a1a]" ref={screen} onPaste={paste} />
      {/* Where a paste lands on its way into the page; see above. */}
      <textarea
        ref={catcher}
        className="pointer-events-none fixed top-0 left-0 size-px opacity-0"
        onPaste={paste}
        tabIndex={-1}
        aria-hidden="true"
      />
    </div>
  )
}
