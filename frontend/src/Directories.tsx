import { ChevronLeft, ChevronRight, Folder, X } from "lucide-react"
import { useEffect, useState } from "react"
import type { AgentInfo } from "./api"
import { RenameInput } from "./Confirm"
import { basename, join, listing, normalize, parent, rebase, ROOT, within } from "./directories"
import { ago } from "./format"
import { RowMenu } from "./RowMenu"
import { lastActive } from "./useLobby"

/**
 * Every directory, as columns: the root's directories first, and each one
 * picked opens the next column with what is inside it — its directories, then
 * its sessions. Finder's column view, over prefixes (see `directories.ts`).
 *
 * The root's own sessions are the sidebar's list, so its column holds only
 * directories. On a phone there is room for one column; a back button goes up.
 */
export function Directories({
  sessions,
  activeId,
  narrow,
  onSelect,
  onMoveSession,
  onDeleteSession,
  onMoveDirectory,
  onRenameDirectory,
  onClose,
}: {
  sessions: AgentInfo[]
  activeId: string | null
  narrow: boolean
  onSelect: (id: string) => void
  onMoveSession: (id: string) => void
  onDeleteSession: (id: string) => void
  onMoveDirectory: (dir: string) => void
  onRenameDirectory: (from: string, to: string) => Promise<void>
  onClose: () => void
}) {
  // The directory whose contents the last column shows; the root shows the first.
  const [open, setOpen] = useState(ROOT)
  const [renaming, setRenaming] = useState<string | null>(null)

  // Moved away under us (here or on another device): stay with what is left.
  const exists = (dir: string) => dir === ROOT || sessions.some((s) => within(s.directory ?? ROOT, dir))
  useEffect(() => {
    if (!exists(open)) setOpen(ROOT)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sessions, open])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      // Taken already: a rename box putting the old name back, a menu closing.
      if (e.key !== "Escape" || e.defaultPrevented) return
      onClose()
    }
    document.addEventListener("keydown", onKey)
    return () => document.removeEventListener("keydown", onKey)
  }, [onClose])

  const chain = open === ROOT ? [ROOT] : [ROOT, ...open.split("/").map((_, i, a) => a.slice(0, i + 1).join("/"))]
  const columns = narrow ? [open] : chain
  const count = (dir: string) => sessions.filter((s) => within(s.directory ?? ROOT, dir)).length

  const rename = async (from: string, name: string | null) => {
    setRenaming(null)
    if (name === null) return
    const to = join(parent(from), normalize(name.replaceAll("/", " ")))
    if (to === from || normalize(name) === "") return
    await onRenameDirectory(from, to)
    setOpen((o) => rebase(o, from, to) ?? o)
  }

  return (
    <div className="modal-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal directories" role="dialog" aria-label="Directories">
        <div className="modal-head">
          <span className="directories-title">
            {narrow && open !== ROOT && (
              <button className="pane-btn" onClick={() => setOpen(parent(open))} title="Up">
                <ChevronLeft />
              </button>
            )}
            {open === ROOT ? "Directories" : open}
          </span>
          <button className="pane-btn" onClick={onClose} title="Close (Esc)">
            <X />
          </button>
        </div>
        <div className="directory-columns">
          {columns.map((dir) => {
            const { dirs, sessions: here } = listing(sessions, dir)
            const shown = dir === ROOT ? [] : [...here].sort((a, b) => lastActive(b) - lastActive(a))
            return (
              <div className="directory-column" key={dir || "/"}>
                {dirs.map((d) => (
                  <div
                    key={d}
                    className={"session directory" + (within(open, d) ? " active" : "")}
                    onClick={() => setOpen(d)}
                  >
                    <Folder />
                    {renaming === d ? (
                      <RenameInput value={basename(d)} stem={false} onDone={(name) => rename(d, name)} />
                    ) : (
                      <span className="session-label">{basename(d)}</span>
                    )}
                    <span className="session-when">{count(d)}</span>
                    <RowMenu
                      items={[
                        { label: "Rename", run: () => setRenaming(d) },
                        { label: "Move to…", run: () => onMoveDirectory(d) },
                      ]}
                    />
                    <ChevronRight className="directory-chevron" />
                  </div>
                ))}
                {shown.map((s) => (
                  <div
                    key={s.id}
                    className={"session" + (s.id === activeId ? " active" : "")}
                    onClick={() => {
                      onSelect(s.id)
                      onClose()
                    }}
                  >
                    <span className={"dot " + s.status} title={s.status} />
                    <span className="session-label">{s.title ?? s.id}</span>
                    <span className="session-when">{ago(lastActive(s))}</span>
                    <RowMenu
                      items={[
                        { label: "Move to…", run: () => onMoveSession(s.id) },
                        { label: "Delete", danger: true, run: () => onDeleteSession(s.id) },
                      ]}
                    />
                  </div>
                ))}
                {dirs.length === 0 && shown.length === 0 && (
                  <div className="session-empty">
                    {dir === ROOT ? "No directories yet. Use “Move to…” on a session to make one." : "Empty."}
                  </div>
                )}
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}
