import { Folder } from "lucide-react"
import { useEffect, useMemo, useRef, useState } from "react"
import { normalize, ROOT } from "./directories"
import { fuzzyFilter } from "./fuzzy"
import { isComposing } from "./ime"

type Choice = { dir: string; fresh: boolean }

const anywhere = () => true

/**
 * "Move to": pick a directory, or type a path that does not exist yet. Making
 * one is just moving something into it — directories are only prefixes, see
 * `directories.ts`.
 *
 * Arrows (or C-n / C-p) choose, Enter moves, Esc gives up; while an IME is
 * composing, Enter and Esc are its own.
 */
export function MovePicker({
  title,
  dirs,
  current,
  allowed = anywhere,
  onPick,
  onClose,
}: {
  title: string
  dirs: string[]
  // Where it is now, marked in the list.
  current: string
  // What it may not go into: a directory into itself or under itself.
  allowed?: (dir: string) => boolean
  onPick: (dir: string) => Promise<void>
  onClose: () => void
}) {
  const [typed, setTyped] = useState("")
  const [sel, setSel] = useState(0)
  const [error, setError] = useState<string | null>(null)
  const input = useRef<HTMLInputElement>(null)
  useEffect(() => input.current?.focus(), [])

  const choices = useMemo<Choice[]>(() => {
    const known = [ROOT, ...dirs].filter(allowed)
    const path = normalize(typed)
    const matched = typed.trim() === "" ? known : fuzzyFilter(typed, known, (d) => d || "/")
    const list = matched.map((dir) => ({ dir, fresh: false }))
    return path !== "" && !known.includes(path) && allowed(path) ? [{ dir: path, fresh: true }, ...list] : list
  }, [typed, dirs, allowed])

  useEffect(() => setSel(0), [typed])

  const pick = async (choice: Choice | undefined) => {
    if (!choice) return
    try {
      await onPick(choice.dir)
      onClose()
    } catch (e) {
      setError((e as Error).message)
    }
  }

  return (
    <div className="modal-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal picker" role="dialog" aria-label={title}>
        <div className="modal-head">{title}</div>
        <input
          ref={input}
          className="picker-input"
          placeholder="Directory, or a new path like work/aws"
          value={typed}
          onChange={(e) => {
            setTyped(e.target.value)
            setError(null)
          }}
          onKeyDown={(e) => {
            if (isComposing(e)) return
            const down = e.key === "ArrowDown" || (e.ctrlKey && e.key === "n")
            const up = e.key === "ArrowUp" || (e.ctrlKey && e.key === "p")
            if (down || up) {
              e.preventDefault()
              setSel((i) => Math.max(0, Math.min(choices.length - 1, i + (down ? 1 : -1))))
            } else if (e.key === "Enter") {
              e.preventDefault()
              void pick(choices[sel])
            } else if (e.key === "Escape") {
              e.preventDefault()
              e.stopPropagation()
              onClose()
            }
          }}
        />
        {error && <div className="picker-error">{error}</div>}
        <div className="picker-list">
          {choices.map((c, i) => (
            <div
              key={(c.fresh ? "+" : "") + c.dir}
              ref={i === sel ? (el) => el?.scrollIntoView({ block: "nearest" }) : undefined}
              className={"picker-row" + (i === sel ? " selected" : "")}
              onMouseEnter={() => setSel(i)}
              onClick={() => void pick(c)}
            >
              <Folder />
              <span className="picker-path">{c.dir === ROOT ? "/" : c.dir}</span>
              {c.fresh && <span className="picker-note">new</span>}
              {!c.fresh && c.dir === current && <span className="picker-note">here now</span>}
            </div>
          ))}
          {choices.length === 0 && <div className="picker-empty">Nothing matches.</div>}
        </div>
      </div>
    </div>
  )
}
