import { useEffect, useRef, type RefObject } from "react"

// How far a finger has to travel sideways before it counts, and how much more
// sideways than vertical it has to be. Below either, it is a scroll.
const DISTANCE = 50
const SLOPE = 2

/**
 * Call `onSwipe` when a finger crosses `ref` horizontally in `direction`.
 *
 * Not from the screen edge specifically: there iOS Safari's own back gesture
 * wins and a page cannot cancel it, so a swipe that only worked from the edge
 * would mostly navigate away instead. Anywhere in the element works.
 *
 * Listeners are passive — this never blocks scrolling, it only watches. A touch
 * that starts on something that can itself scroll that way (a wide code block
 * already scrolled across) is left to that element.
 */
export function useSwipe(
  ref: RefObject<HTMLElement | null>,
  direction: "left" | "right",
  enabled: boolean,
  onSwipe: () => void,
) {
  const callback = useRef(onSwipe)
  callback.current = onSwipe

  useEffect(() => {
    const el = ref.current
    if (!el || !enabled) return

    let start: { x: number; y: number } | null = null

    const onStart = (e: TouchEvent) => {
      const touch = e.touches[0]
      start =
        e.touches.length === 1 && !scrollsToward(e.target, el, direction)
          ? { x: touch.clientX, y: touch.clientY }
          : null
    }

    const onMove = (e: TouchEvent) => {
      if (!start) return
      const touch = e.touches[0]
      const dx = (touch.clientX - start.x) * (direction === "right" ? 1 : -1)
      const dy = Math.abs(touch.clientY - start.y)

      // Clearly a vertical scroll: stop watching this touch.
      if (dy > 20 && dy > Math.abs(dx)) {
        start = null
        return
      }
      if (dx > DISTANCE && dx > dy * SLOPE) {
        start = null
        callback.current()
      }
    }

    const onEnd = () => {
      start = null
    }

    el.addEventListener("touchstart", onStart, { passive: true })
    el.addEventListener("touchmove", onMove, { passive: true })
    el.addEventListener("touchend", onEnd, { passive: true })
    el.addEventListener("touchcancel", onEnd, { passive: true })
    return () => {
      el.removeEventListener("touchstart", onStart)
      el.removeEventListener("touchmove", onMove)
      el.removeEventListener("touchend", onEnd)
      el.removeEventListener("touchcancel", onEnd)
    }
  }, [ref, direction, enabled])
}

// Whether something between the touch and `root` would scroll its content if
// the finger moved that way. A finger moving right reveals what is to the left,
// so that needs `scrollLeft > 0`; moving left needs room on the right.
function scrollsToward(
  target: EventTarget | null,
  root: HTMLElement,
  direction: "left" | "right",
): boolean {
  for (let node = target as HTMLElement | null; node && node !== root; node = node.parentElement) {
    if (node.scrollWidth <= node.clientWidth) continue
    if (direction === "right" ? node.scrollLeft > 0 : node.scrollLeft + node.clientWidth < node.scrollWidth - 1)
      return true
  }
  return false
}
