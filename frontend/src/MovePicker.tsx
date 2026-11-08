import { Folder, FolderPlus, X } from "lucide-react"
import { useEffect, useState } from "react"
import { isComposing } from "./ime"

/** A directory name as one: no slashes, so directories stay one level deep. */
export const dirName = (typed: string) => typed.replaceAll("/", " ").trim().replace(/\s+/g, " ")

/**
 * Where a session can go: a new directory, named in the box, or one there is
 * already. Making a directory is just moving something into it — they are
 * only prefixes, see `directories.ts`.
 *
 * The desktop's row menu shows it beside "Move to directory"; a phone shows it
 * in `MovePicker`. The box is never focused for you, so a phone's keyboard
 * comes up only when a new name is wanted.
 */
export function MoveTargets({
  dirs,
  current,
  onPick,
}: {
  dirs: string[]
  // Where it is now, left out.
  current: string
  onPick: (dir: string) => Promise<void>
}) {
  const [typed, setTyped] = useState("")
  const [error, setError] = useState<string | null>(null)
  const pick = async (dir: string) => {
    if (dir === "" || dir === current) return
    try {
      await onPick(dir)
    } catch (e) {
      setError((e as Error).message)
    }
  }
  const others = dirs.filter((d) => d !== current)

  return (
    <div className="move-targets">
      <label className="move-new">
        <FolderPlus />
        <input
          placeholder="New directory"
          value={typed}
          onChange={(e) => {
            setTyped(e.target.value)
            setError(null)
          }}
          onKeyDown={(e) => {
            if (isComposing(e) || e.key !== "Enter") return
            e.preventDefault()
            void pick(dirName(typed))
          }}
        />
      </label>
      {error && <div className="picker-error">{error}</div>}
      {others.length > 0 && <hr className="row-menu-rule" />}
      {others.map((d) => (
        <button key={d} onClick={() => void pick(d)}>
          <Folder />
          <span>{d}</span>
        </button>
      ))}
    </div>
  )
}

/** "Move to directory" on a phone: `MoveTargets`, nearly the whole screen. */
export function MovePicker({
  title,
  dirs,
  current,
  onPick,
  onClose,
}: {
  title: string
  dirs: string[]
  current: string
  onPick: (dir: string) => Promise<void>
  onClose: () => void
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose()
    document.addEventListener("keydown", onKey)
    return () => document.removeEventListener("keydown", onKey)
  }, [onClose])

  return (
    <div className="modal-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal picker" role="dialog" aria-label={title}>
        <div className="modal-head">
          <span className="modal-title">{title}</span>
          <button className="pane-btn" onClick={onClose} title="Close">
            <X />
          </button>
        </div>
        <MoveTargets
          dirs={dirs}
          current={current}
          onPick={async (dir) => {
            await onPick(dir)
            onClose()
          }}
        />
      </div>
    </div>
  )
}
