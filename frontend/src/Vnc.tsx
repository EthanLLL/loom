import { useEffect, useRef, useState, type ReactNode } from "react"
import RFB from "@novnc/novnc"
import { ArrowLeft01Icon, ArrowRightToLineIcon, ArrowTurnBackwardIcon, Cancel01Icon, DeletePutBackIcon, KeyboardIcon, Maximize01Icon, Minimize01Icon, ReloadIcon, SentIcon, ZoomInAreaIcon, ZoomOutAreaIcon } from "@hugeicons/core-free-icons"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { useNativeAction, usePost } from "./native"
import { PaneButton, PaneHead, PaneTitle } from "./Pane"
import { meter, type VncStats } from "./vncMeter"

/** Where the screen comes from: a WebSocket's URL, or a line already open. */
export type VncLine = {
  channel: string | WebSocket | RTCDataChannel
  // Said beside the title, e.g. how the line goes.
  note?: string
  // For loom-mac-screen (its Capture.Line): the Mac's own network, across
  // the internet or a relay, or round by loom (and when not said).
  kind?: "lan" | "wan" | "narrow"
  close?: () => void
}

/**
 * A screen over VNC, drawn by noVNC, in a pane of the right-hand column:
 * loom's own browser (Browser.tsx) or one of the user's devices (Desktop.tsx).
 * `open` is asked for a line on every attempt; a failure it throws, or the
 * reason a WebSocket is closed with, is what the pane says.
 *
 * `native` names the iOS app's actions and pane state (ios/Pane.tsx), for the
 * one shown there. `login` is where to remember the user name, for a screen
 * that asks for one (a Mac's).
 */
export function VncPane({
  title,
  open,
  native,
  login,
  narrow,
  maximized,
  onToggleMaximized,
  onClose,
}: {
  title: ReactNode
  open: () => Promise<VncLine>
  native?: string
  login?: string
  narrow: boolean
  maximized: boolean
  onToggleMaximized: () => void
  onClose: () => void
}) {
  const screen = useRef<HTMLDivElement>(null)
  const catcher = useRef<HTMLTextAreaElement>(null)
  const rfb = useRef<RFB | null>(null)
  const [state, setState] = useState<"connecting" | "connected" | "closed">("connecting")
  const [note, setNote] = useState<string | null>(null)
  const [stats, setStats] = useState<VncStats | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [asking, setAsking] = useState(false)
  const [attempt, setAttempt] = useState(0)
  // Fit the whole screen in the pane, or show it at 1:1 and pan by dragging;
  // a phone wants the second to read anything.
  const [fit, setFit] = useState(!narrow)
  const [typing, setTyping] = useState(false)
  const [text, setText] = useState("")

  useNativeAction(`${native}-reconnect`, () => setAttempt((n) => n + 1))
  useNativeAction(`${native}-keyboard`, () => setTyping((t) => !t))
  useNativeAction(`${native}-fit`, () => setFit((f) => !f))
  usePost({ pane: { kind: native, state, typing, fit } }, native !== undefined)

  // `open` is the caller's and changes every render; an attempt is what
  // starts a new line.
  const opener = useRef(open)
  opener.current = open

  useEffect(() => {
    const el = screen.current
    if (!el) return
    let gone = false
    let line: VncLine | null = null
    let r: RFB | null = null
    let stopMeter = () => {}
    setState("connecting")
    setNote(null)
    setStats(null)
    setError(null)
    setAsking(false)

    void (async () => {
      try {
        line = await opener.current()
      } catch (e) {
        if (!gone) {
          setError((e as Error).message)
          setState("closed")
        }
        return
      }
      if (gone) {
        line.close?.()
        return
      }
      setNote(line.note ?? null)
      // Opened here rather than by noVNC, so the reason it is closed with can
      // be read.
      const channel = typeof line.channel === "string" ? new WebSocket(line.channel) : line.channel
      let reason = ""
      channel.addEventListener("close", (e) => {
        reason = (e as CloseEvent).reason ?? ""
      })
      r = new RFB(el, channel, { wsProtocols: [] })
      r.background = "transparent"
      r.addEventListener("connect", () => setState("connected"))
      r.addEventListener("disconnect", () => {
        setAsking(false)
        setState("closed")
        // The close event may land after noVNC's.
        setTimeout(() => !gone && reason && setError(reason))
      })
      r.addEventListener("credentialsrequired", () => setAsking(true))
      r.addEventListener("securityfailure", (e) =>
        setError((e as CustomEvent<{ reason?: string }>).detail.reason || "the login was refused"),
      )
      rfb.current = r
      stopMeter = meter(r, channel, setStats)
    })()

    return () => {
      gone = true
      stopMeter()
      rfb.current = null
      r?.disconnect()
      line?.close?.()
    }
  }, [attempt])

  useEffect(() => {
    if (rfb.current) setView(rfb.current, fit, narrow)
  }, [fit, narrow, state])

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
            <PaneTitle>{title}</PaneTitle>
            {state === "connected" && (note || stats) && (
              <span className="shrink-0 text-xs tabular-nums" title="frames drawn and data received in the last second; the encoding most of it came in">
                {[note, stats && `${stats.fps} fps`, stats && `${stats.mbps.toFixed(1)} Mbps`, stats?.encoding]
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
      <div className="relative min-h-0 flex-1">
        <div className="absolute inset-0 bg-[#1a1a1a]" ref={screen} onPaste={paste} />
        {(asking || error) && (
          <div className="absolute inset-0 flex items-center justify-center p-4 font-sans">
            {asking ? (
              <Login
                storeKey={login}
                onSubmit={(username, password) => {
                  setAsking(false)
                  rfb.current?.sendCredentials({ username, password })
                }}
              />
            ) : (
              <p className="max-w-sm rounded-lg bg-background px-4 py-3 text-sm text-muted-foreground shadow">{error}</p>
            )}
          </div>
        )}
      </div>
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

function setView(r: RFB, fit: boolean, narrow: boolean) {
  r.scaleViewport = fit
  r.clipViewport = !fit
  r.dragViewport = !fit && narrow
}

/**
 * The screen's own login — a Mac's user and password. The name is kept on
 * this device for next time; the password is left to the browser's password
 * manager, which the field names invite.
 */
function Login({ storeKey, onSubmit }: { storeKey?: string; onSubmit: (username: string, password: string) => void }) {
  const key = storeKey && `loom_vnc_user:${storeKey}`
  const [username, setUsername] = useState(() => (key && localStorage.getItem(key)) || "")
  const [password, setPassword] = useState("")
  return (
    <form
      className="flex w-full max-w-xs flex-col gap-2 rounded-xl bg-background p-4 shadow"
      onSubmit={(e) => {
        e.preventDefault()
        if (key) localStorage.setItem(key, username)
        onSubmit(username, password)
      }}
    >
      <div className="text-sm font-medium">Log in to this screen</div>
      <Input
        value={username}
        onChange={(e) => setUsername(e.target.value)}
        placeholder="User"
        name="username"
        autoComplete="username"
        autoCapitalize="off"
        autoCorrect="off"
        spellCheck={false}
        autoFocus={username === ""}
        className="max-sm:text-base"
      />
      <Input
        type="password"
        value={password}
        onChange={(e) => setPassword(e.target.value)}
        placeholder="Password"
        name="password"
        autoComplete="current-password"
        autoFocus={username !== ""}
        className="max-sm:text-base"
      />
      <Button type="submit" disabled={password === ""}>
        Connect
      </Button>
    </form>
  )
}
