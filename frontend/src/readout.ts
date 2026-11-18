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
