import { useEffect, useRef, useState } from "react"
import { isComposing } from "./ime"

/**
 * "Are you sure?" for something that cannot be undone, as a dialog: the
 * buttons, or `y` and `n` (Esc too) from the keyboard. Enter does nothing, so a
 * key meant for something else cannot say yes.
 */
export function Confirm({
  title,
  detail,
  action = "Delete",
  onYes,
  onClose,
}: {
  title: string
  detail?: string
  action?: string
  onYes: () => Promise<void> | void
  onClose: () => void
}) {
  const [error, setError] = useState<string | null>(null)
  const busy = useRef(false)
  const yes = async () => {
    if (busy.current) return
    busy.current = true
    try {
      await onYes()
      onClose()
    } catch (e) {
      setError((e as Error).message)
      busy.current = false
    }
  }
  const latest = useRef({ yes, onClose })
  latest.current = { yes, onClose }

  useEffect(() => {
    // Capturing, and stopped: the app's own keys, and its Esc out of the full
    // window, must not see these too.
    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return
      const key = e.key.toLowerCase()
      if (key !== "y" && key !== "n" && key !== "escape") return
      e.preventDefault()
      e.stopPropagation()
      if (key === "y") void latest.current.yes()
      else latest.current.onClose()
    }
    window.addEventListener("keydown", onKey, true)
    return () => window.removeEventListener("keydown", onKey, true)
  }, [])

  return (
    <div className="modal-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal confirm" role="alertdialog" aria-label={title}>
        <div className="modal-head">{title}</div>
        <div className="confirm-body">
          {detail && <p>{detail}</p>}
          {error && <p className="confirm-error">{error}</p>}
          <div className="confirm-actions">
            <button className="text-btn" onClick={onClose}>
              Cancel <kbd>n</kbd>
            </button>
            <button className="text-btn danger" onClick={() => void yes()}>
              {action} <kbd>y</kbd>
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}

/**
 * A name edited in place. Enter keeps it, Esc puts the old one back, and so
 * does leaving it unchanged; a blur keeps what was typed. While an IME is
 * composing, Enter and Esc are the IME's (see ime.ts).
 *
 * A file's stem is selected to start with, as Finder does, so typing replaces
 * the name and keeps the extension; anything else (`stem` false) is selected
 * whole.
 */
export function RenameInput({
  value,
  onDone,
  stem = true,
  className,
}: {
  value: string
  stem?: boolean
  // The new name, or null to leave it as it was.
  onDone: (name: string | null) => void | Promise<void>
  className?: string
}) {
  const [draft, setDraft] = useState(value)
  const [error, setError] = useState<string | null>(null)
  const ref = useRef<HTMLInputElement>(null)
  const done = useRef(false)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    el.focus()
    const dot = value.lastIndexOf(".")
    el.setSelectionRange(0, stem && dot > 0 ? dot : value.length)
  }, [value, stem])

  const finish = async (name: string | null) => {
    if (done.current) return
    const trimmed = name?.trim() ?? ""
    if (name === null || trimmed === "" || trimmed === value) {
      done.current = true
      await onDone(null)
      return
    }
    done.current = true
    try {
      await onDone(trimmed)
    } catch (e) {
      // Taken, or not a usable name: say so and let it be fixed.
      done.current = false
      setError((e as Error).message)
      ref.current?.focus()
    }
  }

  return (
    <span className={"rename " + (className ?? "")}>
      <input
        ref={ref}
        className="rename-input"
        value={draft}
        onChange={(e) => {
          setDraft(e.target.value)
          setError(null)
        }}
        onClick={(e) => e.stopPropagation()}
        onMouseDown={(e) => e.stopPropagation()}
        // Leaving after a refusal gives up rather than asking again.
        onBlur={() => void finish(error ? null : draft)}
        onKeyDown={(e) => {
          if (isComposing(e)) return
          if (e.key === "Enter") {
            e.preventDefault()
            void finish(draft)
          } else if (e.key === "Escape") {
            e.preventDefault()
            void finish(null)
          }
        }}
      />
      {error && <span className="rename-error">{error}</span>}
    </span>
  )
}
