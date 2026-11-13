import { Cancel01Icon } from "@hugeicons/core-free-icons"
import { HugeiconsIcon } from "@hugeicons/react"
import { Button } from "@/components/ui/button"

/**
 * Messages waiting for the current turn, or parked by an interrupt.
 *
 * Showing them matters most in the interrupted case: they were written for a
 * trajectory that no longer exists, so the user needs to see what is about to
 * be sent and be able to drop a line that no longer applies.
 */
export function QueuePanel({
  messages,
  interrupted,
  onDrop,
}: {
  messages: string[]
  interrupted: boolean
  onDrop: (index: number) => void
}) {
  return (
    <div className="mx-auto w-full max-w-3xl shrink-0 px-4 max-sm:px-3">
      <div
        className={
          "rounded-xl border px-3 py-2 " +
          (interrupted ? "border-destructive/40 bg-destructive/5" : "bg-card")
        }
      >
        <div className="pb-1 text-xs text-muted-foreground">
          {/* Only reachable when the backend refused to take the message into
              the running turn, or when the session was stopped. A message
              typed mid-turn normally goes straight in. */}
          {interrupted
            ? `${messages.length} message${messages.length > 1 ? "s" : ""} parked — they go out with your next one`
            : `${messages.length} waiting — the turn would not take it`}
        </div>
        {messages.map((text, i) => (
          <div className="flex items-center gap-2" key={i}>
            <span className="min-w-0 flex-1 truncate text-sm">{text}</span>
            <Button
              variant="ghost"
              size="icon-xs"
              className="text-muted-foreground hover:text-destructive"
              title="Discard this message"
              aria-label="Discard this message"
              onClick={() => onDrop(i)}
            >
              <HugeiconsIcon icon={Cancel01Icon} />
            </Button>
          </div>
        ))}
      </div>
    </div>
  )
}
