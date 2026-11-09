import { useRef, useState } from "react"
import { moved } from "./directories"

type Drag = { item: string; order: string[] }

/**
 * Dragging rows into order, with pointer events so a mouse and a finger work
 * alike. A mouse drags once it has moved a few pixels; a finger holds still
 * for a moment first, since a plain swipe scrolls the list.
 *
 * While a drag is on, `order` is the list as it would land, for the caller to
 * render; letting go hands it to `onDrop` if it changed. The click that ends a
 * drag is swallowed — `clicked()` says whether to ignore it.
 *
 * Where a row lands is counted from the other rows' midpoints, read from the
 * elements given to `row` (the row itself, not whatever it unfolds into).
 */
export function useDragOrder(items: string[], onDrop: (order: string[]) => void) {
  const [drag, setDrag] = useState<Drag | null>(null)
  const rows = useRef(new Map<string, HTMLElement>())
  const swallow = useRef(false)

  const start = (item: string) => (e: React.PointerEvent<HTMLElement>) => {
    if (e.button !== 0 || (e.target as Element).closest("button, input")) return
    const el = e.currentTarget
    const pointer = e.pointerId
    const [x0, y0] = [e.clientX, e.clientY]
    const touch = e.pointerType !== "mouse"
    let on = false
    let order = items

    const begin = () => {
      on = true
      try {
        el.setPointerCapture(pointer)
      } catch {
        // Lifted already; the pointerup that ends it is on its way.
      }
      setDrag({ item, order })
    }
    const move = (ev: PointerEvent) => {
      if (ev.pointerId !== pointer) return
      if (!on) {
        const far = Math.hypot(ev.clientX - x0, ev.clientY - y0)
        if (touch) return void (far > 8 && end())
        if (far <= 4) return
        begin()
      }
      const above = order.filter((d) => {
        const r = d !== item && rows.current.get(d)?.getBoundingClientRect()
        return r && r.top + r.height / 2 < ev.clientY
      })
      const next = moved(order, item, above.length)
      if (next.join("\0") !== order.join("\0")) {
        order = next
        setDrag({ item, order })
      }
    }
    // A finger's drag must not scroll the list under it. Listened for from the
    // start, as a browser decides at touchstart whether it may scroll freely.
    const noScroll = (ev: TouchEvent) => on && ev.preventDefault()
    const up = (ev: PointerEvent) => {
      if (ev.pointerId !== pointer) return
      if (on) {
        swallow.current = true
        setTimeout(() => (swallow.current = false))
        if (order.join("\0") !== items.join("\0")) onDrop(order)
      }
      end()
    }
    const cancel = (ev: PointerEvent) => ev.pointerId === pointer && end()
    const timer = touch ? setTimeout(begin, 350) : undefined
    const end = () => {
      clearTimeout(timer)
      window.removeEventListener("pointermove", move)
      window.removeEventListener("pointerup", up)
      window.removeEventListener("pointercancel", cancel)
      window.removeEventListener("touchmove", noScroll)
      setDrag(null)
    }
    window.addEventListener("pointermove", move)
    window.addEventListener("pointerup", up)
    window.addEventListener("pointercancel", cancel)
    window.addEventListener("touchmove", noScroll, { passive: false })
  }

  return {
    order: drag?.order ?? items,
    dragging: drag?.item ?? null,
    start,
    row: (item: string) => (el: HTMLElement | null) => {
      if (el) rows.current.set(item, el)
      else rows.current.delete(item)
    },
    clicked: () => swallow.current,
  }
}
