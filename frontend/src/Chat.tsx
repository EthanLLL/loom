import { useCallback, useMemo, useRef, type ReactNode } from "react"
import { buildTimeline, foldTools, isBusy } from "./agent"
import type { AgentInfo, OutputFile } from "./api"
import { itemForPath, type CanvasItem } from "./canvasItems"
import { ChatContext, type ChatScope } from "./chat/context"
import { Composer } from "./chat/Composer"
import { OutputLink as OutputLinkButton } from "./chat/Files"
import { ChatHeader } from "./chat/Header"
import { QueuePanel } from "./chat/QueuePanel"
import { Timeline } from "./chat/Timeline"
import { OutputLink } from "./markdown"
import { useAgent } from "./useAgent"
import { useAttachments, useFileDrop } from "./useAttachments"

type Props = {
  session: AgentInfo
  sidebarOpen: boolean
  onToggleSidebar: () => void
  terminalOpen: boolean
  terminalCount: number
  onToggleTerminal: () => void
  canvasOpen: boolean
  onToggleCanvas: () => void
  onOpenCanvas: (item: CanvasItem) => void
  // A turn left outputs (their top-level paths), or a message brought
  // attachments (no paths).
  onFilesChanged: (outputs: string[]) => void
}

/**
 * One conversation: its bar, the transcript, anything queued, and the box to
 * write in. The parts live in `chat/`; this holds the session's state — the
 * transcript from its channel and the attachments on their way — and hands
 * each part what it needs.
 */
export function Chat({
  session,
  sidebarOpen,
  onToggleSidebar,
  terminalOpen,
  terminalCount,
  onToggleTerminal,
  canvasOpen,
  onToggleCanvas,
  onOpenCanvas,
  onFilesChanged,
}: Props) {
  // The app passes a fresh function each render; reaching it through a ref
  // keeps what the transcript sees stable, so its memoised entries stay put.
  const openRef = useRef(onOpenCanvas)
  openRef.current = onOpenCanvas
  const openCanvas = useCallback((item: CanvasItem) => openRef.current(item), [])

  const { transcript, joinError, submit, interrupt, dropQueued, rename } = useAgent(
    session.id,
    (event) => {
      if (event.kind === "output_files") {
        const files = (event.payload.files as OutputFile[] | undefined) ?? []
        onFilesChanged(files.map((f) => f.path))
      } else if (event.kind === "user") onFilesChanged([])
      // A turn that just built a page opens it — only then, and only for the
      // page. Anything else waits for a click.
      const open = event.kind === "output_files" ? event.payload.open : null
      if (typeof open === "string") {
        const item = itemForPath(open)
        if (item) openCanvas(item)
      }
    },
  )
  const busy = isBusy(transcript)
  // Kept while the transcript is: the timeline follows the end whenever the
  // items change, so a fresh array on every render (the app's keys re-render
  // it) would pull it back down just after `gg` or `k` scrolled it up.
  const items = useMemo(() => foldTools(buildTimeline(transcript), busy), [transcript, busy])

  const scope = useMemo<ChatScope>(
    () => ({ sessionId: session.id, openCanvas, answer: submit }),
    [session.id, openCanvas, submit],
  )
  // `output/…` links in a reply open in the canvas or download; see markdown.tsx.
  const renderOutput = useCallback(
    (path: string, label: ReactNode) => <OutputLinkButton path={path} label={label} />,
    [],
  )

  const attachments = useAttachments(session.id)
  // Dropping is accepted anywhere in the conversation, not just on the
  // composer: by the time you have dragged a screenshot this far, aiming at a
  // 40-pixel target is the last thing you want to do.
  const drop = useFileDrop(attachments.add)

  const send = (text: string) => {
    submit(text, attachments.ready)
    attachments.clear()
  }

  return (
    <ChatContext.Provider value={scope}>
      <div
        className={
          "chat flex min-h-0 min-w-0 flex-1 flex-col bg-background font-sans text-foreground" +
          (drop.dragging ? " outline-1 -outline-offset-2 outline-primary outline-dashed" : "")
        }
        {...drop.handlers}
      >
        {/* A band at the top rather than an overlay: an overlay over the
            transcript would hide what you are attaching the file to. */}
        {drop.dragging && (
          <div className="shrink-0 bg-primary px-4 py-1 text-center text-sm text-primary-foreground">
            Drop to attach to this conversation
          </div>
        )}

        <ChatHeader
          session={session}
          transcript={transcript}
          sidebarOpen={sidebarOpen}
          onToggleSidebar={onToggleSidebar}
          terminalOpen={terminalOpen}
          terminalCount={terminalCount}
          onToggleTerminal={onToggleTerminal}
          canvasOpen={canvasOpen}
          onToggleCanvas={onToggleCanvas}
          onRename={rename}
        />

        {joinError && (
          <div className="shrink-0 bg-destructive/10 px-4 py-1.5 text-sm text-destructive">{joinError}</div>
        )}

        <OutputLink.Provider value={renderOutput}>
          <Timeline items={items} truncatedBefore={transcript.truncatedBefore} />
        </OutputLink.Provider>

        {transcript.queue.length > 0 && (
          <QueuePanel
            messages={transcript.queue}
            interrupted={transcript.status === "interrupted"}
            onDrop={dropQueued}
          />
        )}

        <Composer
          sessionId={session.id}
          backend={session.backend}
          model={session.model ?? null}
          busy={busy}
          interrupted={transcript.status === "interrupted"}
          attachments={attachments}
          onSubmit={send}
          onInterrupt={interrupt}
        />
      </div>
    </ChatContext.Provider>
  )
}
