import { Cancel01Icon, Folder01Icon, FolderAddIcon } from "@hugeicons/core-free-icons"
import { HugeiconsIcon } from "@hugeicons/react"
import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogClose, DialogContent, DialogTitle } from "@/components/ui/dialog"
import { Separator } from "@/components/ui/separator"
import { isComposing } from "./ime"

/** A directory name as one: no slashes, so directories stay one level deep. */
export const dirName = (typed: string) => typed.replaceAll("/", " ").trim().replace(/\s+/g, " ")

/**
 * "Move to directory" on a phone, where a submenu has no room: where a session
 * can go, nearly the whole screen. A box for a new directory, then the ones
 * there are already, as rows. Making a directory is just moving something into
 * it — they are only prefixes, see `directories.ts`. The box is never focused
 * for you, so the keyboard comes up only when a new name is wanted.
 */
export function MovePicker({
  title,
  dirs,
  current,
  onPick,
  onClose,
}: {
  title: string
  dirs: string[]
  // Where it is now, left out.
  current: string
  onPick: (dir: string) => Promise<void>
  onClose: () => void
}) {
  const [typed, setTyped] = useState("")
  const [error, setError] = useState<string | null>(null)
  const pick = async (dir: string) => {
    if (dir === "" || dir === current) return
    try {
      await onPick(dir)
      onClose()
    } catch (e) {
      setError((e as Error).message)
    }
  }
  const others = dirs.filter((d) => d !== current)

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent
        initialFocus={false}
        showCloseButton={false}
        className="flex max-h-[min(28rem,calc(100dvh-2rem))] flex-col gap-0 p-0 font-sans max-sm:h-[calc(100dvh-2rem)] max-sm:max-h-none"
      >
        <div className="flex shrink-0 items-center gap-2 border-b py-1.5 pr-1.5 pl-4">
          <DialogTitle className="min-w-0 flex-1 truncate">{title}</DialogTitle>
          <DialogClose render={<Button variant="ghost" size="icon-sm" className="text-muted-foreground" />}>
            <HugeiconsIcon icon={Cancel01Icon} />
            <span className="sr-only">Close</span>
          </DialogClose>
        </div>
        <div className="flex min-h-0 flex-col overflow-y-auto p-1.5">
          <label className="flex h-[44px] shrink-0 items-center gap-2.5 rounded-lg px-2.5 focus-within:bg-muted">
            <HugeiconsIcon icon={FolderAddIcon} className="size-5 shrink-0 text-muted-foreground" />
            {/* 16px and up: iOS zooms into a smaller field. */}
            <input
              className="min-w-0 flex-1 bg-transparent text-base outline-none placeholder:text-muted-foreground"
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
          {error && <div className="px-2.5 py-1.5 text-sm text-destructive">{error}</div>}
          {others.length > 0 && <Separator className="my-1.5" />}
          {others.map((d) => (
            <button
              key={d}
              className="flex h-[44px] shrink-0 items-center gap-2.5 rounded-lg px-2.5 text-left text-base hover:bg-muted active:bg-muted"
              onClick={() => void pick(d)}
            >
              <HugeiconsIcon icon={Folder01Icon} className="size-5 shrink-0 text-muted-foreground" />
              <span className="min-w-0 truncate">{d}</span>
            </button>
          ))}
        </div>
      </DialogContent>
    </Dialog>
  )
}
