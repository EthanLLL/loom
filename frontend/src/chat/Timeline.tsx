import { ArrowDown02Icon } from "@hugeicons/core-free-icons"
import { HugeiconsIcon } from "@hugeicons/react"
import { useLayoutEffect, useRef, useState } from "react"
import { Button } from "@/components/ui/button"
import type { TimelineItem } from "../agent"
import { Item } from "./Items"

// How many items are rendered at first, and added each time the reader nears
// the top. A session keeps 500 events; on a phone, laying all of them out
// before the newest one shows is the slow part of opening it.
const PAGE = 60
// How close to the top counts as nearing it, in pixels.
const NEAR_TOP = 600

/**
 * The conversation, scrolled to the end and following it while the reader is
 * there. Scrolling up to read something while the agent streams must not yank
 * them back down.
 */
export function Timeline({
  items,
  truncatedBefore,
}: {
  items: TimelineItem[]
  truncatedBefore: number | null
}) {
  const ref = useRef<HTMLDivElement>(null)
  const pinnedRef = useRef(true)
  // The ref decides whether to follow; this only drives the button, so a
  // scroll that does not cross the line re-renders nothing.
  const [pinned, setPinned] = useState(true)
  // Set while `toBottom` scrolls. A smooth scroll fires scroll events all the
  // way down, and judging those by position would unpin it again — and bring
  // the button straight back — before it lands.
  const jumpingRef = useRef(false)
  // The tail that is rendered. Grows, never shrinks, for this mount.
  const [shown, setShown] = useState(PAGE)
  // The scroll height before more was rendered above, so the reader stays on
  // the line they were reading instead of jumping with the new content.
  const growFromRef = useRef<number | null>(null)
  const hidden = Math.max(0, items.length - shown)
  const visible = hidden > 0 ? items.slice(hidden) : items

  const showMore = () => {
    const el = ref.current
    if (!el || hidden === 0 || growFromRef.current !== null) return
    growFromRef.current = el.scrollHeight
    setShown((n) => n + PAGE)
  }

  useLayoutEffect(() => {
    const el = ref.current
    const from = growFromRef.current
    if (!el || from === null) return
    growFromRef.current = null
    el.scrollTop += el.scrollHeight - from
  }, [shown])

  const onScroll = () => {
    const el = ref.current
    if (!el) return
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 80
    if (el.scrollTop < NEAR_TOP) showMore()
    if (jumpingRef.current) {
      if (!atBottom) return
      jumpingRef.current = false
    }
    pinnedRef.current = atBottom
    setPinned(atBottom)
  }

  // The user taking over mid-jump wins.
  const cancelJump = () => {
    jumpingRef.current = false
  }

  useLayoutEffect(() => {
    const el = ref.current
    if (el && pinnedRef.current) el.scrollTop = el.scrollHeight
  }, [items])

  const toBottom = () => {
    const el = ref.current
    if (!el) return
    // Pinned straight away, not when the smooth scroll lands: output arriving
    // mid-scroll should be followed, not left behind.
    pinnedRef.current = true
    setPinned(true)
    jumpingRef.current = true
    // A long transcript is tens of thousands of pixels: smooth all the way it
    // takes seconds. Cut to a screen above the end, then glide the rest, which
    // still shows which way it went.
    const end = el.scrollHeight - el.clientHeight
    if (end - el.scrollTop > el.clientHeight * 2) el.scrollTop = end - el.clientHeight
    el.scrollTo({ top: el.scrollHeight, behavior: "smooth" })
  }

  return (
    // Holds the scroller and the button floating over its bottom edge, which
    // cannot live inside the scroller without scrolling away with it.
    <div className="relative flex min-h-0 flex-1 flex-col">
      <div
        // `.timeline` is how the app's keys find the scroller (App.tsx).
        className="timeline min-h-0 flex-1 overflow-y-auto"
        ref={ref}
        onScroll={onScroll}
        onWheel={cancelJump}
        onTouchStart={cancelJump}
      >
        {/* The scroll container is the outer element and the measure is this
            one, so the scrollbar stays at the window edge while prose, tool
            calls and turn lines share a single column.

            Every child is `shrink-0`: a column flex container shrinks its
            children before it scrolls, so once a conversation outgrew the
            viewport every entry got squashed — a clipped one down to nothing.
            `min-h-full` lets a short conversation centre its empty state. */}
        <div className="mx-auto flex min-h-full w-full max-w-3xl flex-col gap-4 px-4 pt-6 pb-8 *:shrink-0 max-sm:px-3">
          {hidden > 0 ? (
            // Scrolling up gets here first and loads more on its own; this is
            // for `gg`, which lands on it, and for anyone who would rather click.
            <Button variant="ghost" size="sm" className="self-center text-muted-foreground" onClick={showMore}>
              {hidden} earlier
            </Button>
          ) : truncatedBefore ? (
            <div className="self-center text-sm text-muted-foreground">
              Earlier messages are no longer kept (up to #{truncatedBefore})
            </div>
          ) : null}

          {items.length === 0 && (
            <div className="m-auto text-muted-foreground">Send a message to start.</div>
          )}

          {visible.map((item) => (
            <Item key={item.key} item={item} />
          ))}
        </div>
      </div>

      {!pinned && (
        <Button
          variant="outline"
          size="icon"
          className="absolute bottom-3 left-1/2 z-10 -translate-x-1/2 rounded-full bg-background shadow-md dark:bg-background"
          onClick={toBottom}
          title="Jump to the latest"
          aria-label="Jump to the latest"
        >
          <HugeiconsIcon icon={ArrowDown02Icon} />
        </Button>
      )}
    </div>
  )
}
