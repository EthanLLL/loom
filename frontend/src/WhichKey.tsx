import { useEffect } from "react"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { Kbd } from "@/components/ui/kbd"
import type { Keymap } from "./keys"

const SHOWN: Record<string, string> = { Space: "␣", Esc: "Esc", Enter: "↵" }
const show = (seq: string) =>
  seq
    .split(" ")
    .map((k) => SHOWN[k] ?? k)
    .join("")

/**
 * What can follow the keys typed so far, the way which-key.nvim shows it. A
 * key that only leads further is listed under `groups`' name for it.
 */
export function WhichKey({
  pending,
  keymap,
  groups,
}: {
  pending: string[]
  keymap: Keymap
  groups: Record<string, string>
}) {
  if (pending.length === 0) return null
  const prefix = pending.join(" ") + " "
  const next = new Map<string, string>()
  for (const [seq, binding] of Object.entries(keymap)) {
    if (!seq.startsWith(prefix)) continue
    const rest = seq.slice(prefix.length).split(" ")
    const key = rest[0]
    if (next.has(key)) continue
    next.set(key, rest.length === 1 ? binding.desc : (groups[prefix + key] ?? "…"))
  }
  return (
    // Out of the way in the corner, as a popover.
    <div className="fixed right-4 bottom-4 z-50 min-w-56 rounded-xl bg-popover p-3 font-sans text-sm text-popover-foreground shadow-md ring-1 ring-foreground/10">
      <div className="mb-1.5 text-muted-foreground">{show(pending.join(" "))}</div>
      {[...next].map(([key, desc]) => (
        <KeyRow key={key} keys={show(key)} desc={desc} />
      ))}
    </div>
  )
}

/** Every key, for `?`. `extra` lists the ones not in the keymap. */
export function KeyHelp({
  keymap,
  extra,
  onClose,
}: {
  keymap: Keymap
  extra: [string, string][]
  onClose: () => void
}) {
  // The keymap is off while a dialog is up, this one too; Esc is the dialog's.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "?") onClose()
    }
    document.addEventListener("keydown", onKey)
    return () => document.removeEventListener("keydown", onKey)
  }, [onClose])
  const rows = [...extra, ...Object.entries(keymap).map(([k, b]) => [show(k), b.desc])]
  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="flex max-h-[min(40rem,calc(100dvh-2rem))] flex-col gap-0 p-0 font-sans sm:max-w-md">
        <div className="flex shrink-0 items-baseline gap-2 border-b px-4 py-3 pr-10">
          <DialogTitle>Keys</DialogTitle>
          <DialogDescription className="text-xs">Esc to close</DialogDescription>
        </div>
        <div className="overflow-y-auto px-4 py-3 text-sm">
          {rows.map(([key, desc]) => (
            <KeyRow key={key} keys={key} desc={desc} />
          ))}
        </div>
      </DialogContent>
    </Dialog>
  )
}

function KeyRow({ keys, desc }: { keys: string; desc: string }) {
  return (
    <div className="flex items-center gap-3 py-0.5">
      <span className="min-w-14">
        <Kbd>{keys}</Kbd>
      </span>
      <span>{desc}</span>
    </div>
  )
}
