import { ChevronRight, Ellipsis } from "lucide-react"
import { type ReactNode, useEffect, useRef, useState } from "react"
import { createPortal } from "react-dom"

export type MenuItem =
  | { label: string; icon?: ReactNode; danger?: boolean; run: () => void }
  // Opens beside the menu, on hover or click; `close` shuts both.
  | { label: string; icon?: ReactNode; sub: (close: () => void) => ReactNode }
  // A rule between groups, and a group's dim name over it.
  | { divider: true }
  | { heading: string }

/**
 * The "…" at the end of a row, and what it opens.
 *
 * Drawn on the body, at the button's place on screen: inside the row it would
 * be clipped by the scrolling list it sits in, and on a phone the drawer's
 * transform would move it. Opens upward when there is no room below; a
 * submenu opens to the right, or to the left at the window's edge.
 */
export function RowMenu({ items, title = "More" }: { items: MenuItem[]; title?: string }) {
  const [at, setAt] = useState<DOMRect | null>(null)
  // The submenu's item, by label, and where that row is.
  const [sub, setSub] = useState<{ label: string; row: DOMRect } | null>(null)
  const menu = useRef<HTMLDivElement>(null)
  const close = () => {
    setAt(null)
    setSub(null)
  }

  useEffect(() => {
    if (!at) return
    const away = (e: Event) => {
      if (!menu.current?.contains(e.target as Node)) close()
    }
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return
      // The dialog under it keeps its Esc for itself.
      e.preventDefault()
      e.stopPropagation()
      close()
    }
    document.addEventListener("mousedown", away)
    document.addEventListener("touchstart", away)
    window.addEventListener("keydown", onKey, true)
    // It is pinned to where the button was.
    window.addEventListener("resize", close)
    return () => {
      window.removeEventListener("resize", close)
      document.removeEventListener("mousedown", away)
      document.removeEventListener("touchstart", away)
      window.removeEventListener("keydown", onKey, true)
    }
  }, [at])

  const below = at ? window.innerHeight - at.bottom > items.length * 34 + 16 : true
  const open = sub && items.find((i) => "sub" in i && i.label === sub.label)

  return (
    <>
      <button
        className="row-more"
        title={title}
        onClick={(e) => {
          e.stopPropagation()
          const rect = e.currentTarget.getBoundingClientRect()
          setSub(null)
          setAt((was) => (was ? null : rect))
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
            {items.map((item, i) => {
              if ("divider" in item) return <hr key={i} className="row-menu-rule" />
              if ("heading" in item)
                return (
                  <div key={i} className="row-menu-heading">
                    {item.heading}
                  </div>
                )
              if ("sub" in item) {
                const show = (el: HTMLElement) => setSub({ label: item.label, row: el.getBoundingClientRect() })
                return (
                  <button
                    key={item.label}
                    className={sub?.label === item.label ? "open" : undefined}
                    onMouseEnter={(e) => show(e.currentTarget)}
                    onClick={(e) => show(e.currentTarget)}
                  >
                    {item.icon}
                    <span>{item.label}</span>
                    <ChevronRight className="row-menu-more" />
                  </button>
                )
              }
              return (
                <button
                  key={item.label}
                  className={item.danger ? "danger" : undefined}
                  onMouseEnter={() => setSub(null)}
                  onClick={() => {
                    close()
                    item.run()
                  }}
                >
                  {item.icon}
                  <span>{item.label}</span>
                </button>
              )
            })}
            {open && sub && "sub" in open && (
              <div
                className="row-menu row-submenu"
                style={{
                  top: Math.min(sub.row.top - 6, window.innerHeight - 320),
                  ...(window.innerWidth - sub.row.right > 260
                    ? { left: sub.row.right + 10 }
                    : { right: window.innerWidth - sub.row.left + 10 }),
                }}
              >
                {open.sub(close)}
              </div>
            )}
          </div>,
          document.body,
        )}
    </>
  )
}
