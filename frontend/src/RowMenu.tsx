import { Ellipsis } from "lucide-react"
import { useEffect, useRef, useState } from "react"
import { createPortal } from "react-dom"

export type MenuItem = { label: string; danger?: boolean; run: () => void }

/**
 * The "…" at the end of a row, and what it opens.
 *
 * Drawn on the body, at the button's place on screen: inside the row it would
 * be clipped by the scrolling list it sits in, and on a phone the drawer's
 * transform would move it. Opens upward when there is no room below.
 */
export function RowMenu({ items, title = "More" }: { items: MenuItem[]; title?: string }) {
  const [at, setAt] = useState<DOMRect | null>(null)
  const menu = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!at) return
    const away = (e: Event) => {
      if (!menu.current?.contains(e.target as Node)) setAt(null)
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return
      // The dialog under it keeps its Esc for itself.
      e.preventDefault()
      e.stopPropagation()
      setAt(null)
    }
    document.addEventListener("mousedown", away)
    document.addEventListener("touchstart", away)
    window.addEventListener("keydown", onKey, true)
    // It is pinned to where the button was.
    const close = () => setAt(null)
    window.addEventListener("resize", close)
    return () => {
      window.removeEventListener("resize", close)
      document.removeEventListener("mousedown", away)
      document.removeEventListener("touchstart", away)
      window.removeEventListener("keydown", onKey, true)
    }
  }, [at])

  const below = at ? window.innerHeight - at.bottom > items.length * 34 + 16 : true

  return (
    <>
      <button
        className="row-more"
        title={title}
        onClick={(e) => {
          e.stopPropagation()
          const rect = e.currentTarget.getBoundingClientRect()
          setAt((open) => (open ? null : rect))
        }}
      >
        <Ellipsis />
      </button>
      {at &&
        createPortal(
          <div
            ref={menu}
            className="row-menu"
            style={{
              right: window.innerWidth - at.right,
              ...(below ? { top: at.bottom + 4 } : { bottom: window.innerHeight - at.top + 4 }),
            }}
            onClick={(e) => e.stopPropagation()}
          >
            {items.map((item) => (
              <button
                key={item.label}
                className={item.danger ? "danger" : undefined}
                onClick={() => {
                  setAt(null)
                  item.run()
                }}
              >
                {item.label}
              </button>
            ))}
          </div>,
          document.body,
        )}
    </>
  )
}
