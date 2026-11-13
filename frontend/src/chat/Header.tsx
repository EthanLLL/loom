import { PaintbrushIcon, PanelLeftOpenIcon, SquareTerminalIcon } from "lucide-react"
import { useState } from "react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import type { Transcript } from "../agent"
import type { AgentBackend, AgentInfo } from "../api"
import { BackendIcon } from "../BackendIcon"
import { isComposing } from "../ime"
import { contextPressure, formatTokens } from "./format"

/**
 * The conversation's bar: its name and engine, how it is doing, how full its
 * context is, and the switches for the side panes.
 */
export function ChatHeader({
  session,
  transcript,
  sidebarOpen,
  onToggleSidebar,
  terminalOpen,
  terminalCount,
  onToggleTerminal,
  canvasOpen,
  onToggleCanvas,
  onRename,
}: {
  session: AgentInfo
  transcript: Transcript
  sidebarOpen: boolean
  onToggleSidebar: () => void
  terminalOpen: boolean
  terminalCount: number
  onToggleTerminal: () => void
  canvasOpen: boolean
  onToggleCanvas: () => void
  onRename: (title: string) => void
}) {
  const pressure = contextPressure(transcript)

  return (
    // `.chat-header` keeps the bar's height in step with the sidebar's own
    // (`--head-h`, App.css) and lets Cool Night draw its rule under it. On a
    // phone it also clears the status bar.
    <header className="chat-header flex h-(--head-h) shrink-0 items-center gap-2 border-b bg-background px-3 max-sm:gap-1 max-sm:px-2 max-sm:pt-[max(0px,env(safe-area-inset-top))]">
      {!sidebarOpen && (
        <Button variant="ghost" size="icon" onClick={onToggleSidebar} title="Show sidebar" aria-label="Show sidebar">
          <PanelLeftOpenIcon />
        </Button>
      )}

      <Title
        title={session.title ?? session.id}
        backend={session.backend}
        profile={session.profile ?? null}
        onRename={onRename}
      />

      <div className="flex shrink-0 items-center gap-1.5">
        <StatusBadge status={transcript.status} queued={transcript.queue.length} />
        {transcript.contextTokens > 0 && (
          <Badge
            variant="outline"
            className={
              "tabular-nums " +
              (pressure === "hot" ? "text-destructive" : pressure === "warm" ? "text-amber-500" : "text-muted-foreground")
            }
            title="How big the conversation is now, against the model's window"
          >
            {formatTokens(transcript.contextTokens)}
            {/* The window is fixed per model; on a phone the bar has no room
                for a number that never changes. */}
            {transcript.contextWindow ? (
              <span className="max-sm:hidden">{` / ${formatTokens(transcript.contextWindow)}`}</span>
            ) : null}
          </Badge>
        )}
        <Button
          variant="ghost"
          size="icon"
          aria-pressed={terminalOpen}
          className="relative text-muted-foreground aria-pressed:bg-muted aria-pressed:text-foreground"
          onClick={onToggleTerminal}
          title={
            (terminalOpen ? "Hide" : "Show") +
            ` terminals — ${terminalCount || "none"} running` +
            " (they open in your home directory)"
          }
        >
          <SquareTerminalIcon />
          {terminalCount > 0 && (
            <span className="absolute top-0.5 right-0.5 min-w-3.5 rounded-full bg-primary px-1 text-[0.625rem] leading-3.5 font-semibold text-primary-foreground tabular-nums">
              {terminalCount}
            </span>
          )}
        </Button>
        <Button
          variant="ghost"
          size="icon"
          aria-pressed={canvasOpen}
          className="text-muted-foreground aria-pressed:bg-muted aria-pressed:text-foreground"
          onClick={onToggleCanvas}
          title={(canvasOpen ? "Hide" : "Show") + " the canvas"}
        >
          <PaintbrushIcon />
        </Button>
      </div>
    </header>
  )
}

/**
 * The session name, editable in place.
 *
 * Renaming is loom-local — the title is a sidebar label, not conversation
 * state — so it never goes to the backend and needs no confirmation.
 */
function Title({
  title,
  backend,
  profile,
  onRename,
}: {
  title: string
  backend: AgentBackend
  profile: string | null
  onRename: (title: string) => void
}) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(title)

  const commit = () => {
    const value = draft.trim()
    if (value !== "" && value !== title) onRename(value)
    setEditing(false)
  }

  return (
    <div className="flex min-w-0 flex-1 items-center gap-2 px-1">
      <BackendIcon backend={backend} />
      {editing ? (
        <input
          className="h-7 min-w-0 flex-1 rounded-md border border-ring bg-background px-2 text-sm font-medium outline-none max-sm:text-base"
          value={draft}
          autoFocus
          onChange={(e) => setDraft(e.target.value)}
          onBlur={commit}
          onKeyDown={(e) => {
            if (isComposing(e)) return
            if (e.key === "Enter") commit()
            if (e.key === "Escape") {
              setDraft(title)
              setEditing(false)
            }
          }}
        />
      ) : (
        <span
          className="truncate text-sm font-medium"
          title="Double-click to rename"
          onDoubleClick={() => {
            setDraft(title)
            setEditing(true)
          }}
        >
          {title}
        </span>
      )}
      {/* Which provider the session talks to, when it is not the default. */}
      {profile && (
        <Badge variant="outline" className="text-muted-foreground">
          {profile}
        </Badge>
      )}
    </div>
  )
}

// `starting` is the backend booting — seconds for a cold Claude Code process
// on a session's first turn, or the first after it idled. Saying so beats
// looking hung.
const STATUS: Record<string, { label: string; dot: string }> = {
  idle: { label: "idle", dot: "bg-muted-foreground/50" },
  starting: { label: "starting…", dot: "bg-amber-500 animate-pulse" },
  running: { label: "working", dot: "bg-emerald-500 animate-pulse" },
  interrupted: { label: "stopped", dot: "bg-destructive" },
}

function StatusBadge({ status, queued }: { status: string; queued: number }) {
  const { label, dot } = STATUS[status] ?? { label: status, dot: "bg-muted-foreground/50" }
  return (
    <Badge variant="outline" className="gap-1.5 text-muted-foreground">
      <span className={"size-1.5 rounded-full " + dot} />
      {label}
      {queued > 0 ? ` · ${queued} queued` : ""}
    </Badge>
  )
}
