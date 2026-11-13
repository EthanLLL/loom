import { useEffect, useState } from "react"

const KEY = "loom_viewport_readout"
const EVENT = "loom-viewport-readout"

/** Whether the readout is on, on this device; Settings switches it. */
export function useViewportReadout(): [boolean, (on: boolean) => void] {
  const [on, setOn] = useState(() => localStorage.getItem(KEY) === "1")
  useEffect(() => {
    const sync = () => setOn(localStorage.getItem(KEY) === "1")
    window.addEventListener(EVENT, sync)
    return () => window.removeEventListener(EVENT, sync)
  }, [])
  const set = (value: boolean) => {
    localStorage.setItem(KEY, value ? "1" : "0")
    window.dispatchEvent(new Event(EVENT))
  }
  return [on, set]
}

/**
 * What the browser says about the window, live, in a corner: for chasing the
 * Home Screen app's viewport bugs on a real device (see viewport.ts), where
 * there is no inspector. Off unless switched on in Settings.
 */
export function ViewportReadout() {
  const [on] = useViewportReadout()
  const [text, setText] = useState("")

  useEffect(() => {
    if (!on) return
    // env() is only readable through an element that uses it.
    const probe = document.createElement("div")
    probe.style.cssText =
      "position:fixed;visibility:hidden;pointer-events:none;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)"
    document.body.appendChild(probe)
    let back = ""
    const read = () => {
      const vv = window.visualViewport
      const p = getComputedStyle(probe)
      const inset = [p.paddingTop, p.paddingRight, p.paddingBottom, p.paddingLeft].map((v) => parseFloat(v)).join(" ")
      const root = document.getElementById("root")!.getBoundingClientRect()
      setText(
        [
          `screen ${screen.width}×${screen.height}  inner ${innerWidth}×${innerHeight}`,
          vv && `visual ${Math.round(vv.width)}×${Math.round(vv.height)} @${Math.round(vv.offsetLeft)},${Math.round(vv.offsetTop)}`,
          `root ${Math.round(root.width)}×${Math.round(root.height)} @${Math.round(root.left)},${Math.round(root.top)}  scroll ${scrollX},${scrollY}`,
          `inset t r b l: ${inset}`,
          `${document.documentElement.classList.contains("standalone") ? "standalone" : "browser"}  ${screen.orientation?.type ?? ""}${back}`,
        ]
          .filter(Boolean)
          .join("\n"),
      )
    }
    const onVisible = () => {
      if (document.visibilityState === "visible") back = `  back ${new Date().toLocaleTimeString()}`
      read()
    }
    const timer = setInterval(read, 500)
    window.addEventListener("resize", read)
    document.addEventListener("visibilitychange", onVisible)
    read()
    return () => {
      clearInterval(timer)
      window.removeEventListener("resize", read)
      document.removeEventListener("visibilitychange", onVisible)
      probe.remove()
    }
  }, [on])

  if (!on) return null
  return (
    <pre className="pointer-events-none fixed top-1/2 left-1/2 z-[100] -translate-1/2 rounded-lg bg-black/80 px-3 py-2 font-mono text-xs leading-relaxed whitespace-pre text-white">
      {text}
    </pre>
  )
}
