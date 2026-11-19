import { useCallback, useMemo, useRef, type ReactNode } from "react"
import { buildTimeline, foldTools, isBusy, type Transcript } from "./agent"
import type { AgentInfo, OutputFile } from "./api"
import { itemForPath, type CanvasItem } from "./canvasItems"
import { ChatContext, type ChatScope } from "./chat/context"
import { OutputLink as OutputLinkButton } from "./chat/Files"
import { QueuePanel } from "./chat/QueuePanel"
import { Timeline } from "./chat/Timeline"
import { OutputLink } from "./outputLink"
import { native } from "./native"
import { useAgent } from "./useAgent"
import { useAttachments, useFileDrop, type Attachments } from "./useAttachments"

/** What the bar and the box to write in are drawn from. */
export type ChatParts = {
  session: AgentInfo
  transcript: Transcript
  busy: boolean
  attachments: Attachments
  send: (text: string) => void
  interrupt: () => void
  rename: (title: string) => void
}

type Props = {
  session: AgentInfo
  onOpenCanvas: (item: CanvasItem) => void
  // A turn left outputs (their top-level paths), or a message brought
  // attachments (no paths).
  onFilesChanged: (outputs: string[]) => void
  // The bar and the box are the caller's: the browser's own (chat/Header,
  // chat/Composer), or the iOS app's composer and no bar, the app drawing
  // its own. So each bundle carries only the ones it shows.
  header?: (parts: ChatParts) => ReactNode
  composer: (parts: ChatParts) => ReactNode
}

/**
 * One conversation: its bar, the transcript, anything queued, and the box to
 * write in. The parts live in `chat/`; this holds the session's state — the
 * transcript from its channel and the attachments on their way — and hands
 * each part what it needs.
 */
export function Chat({ session, onOpenCanvas, onFilesChanged, header, composer }: Props) {
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
  // 40-pixel target is the last thing you want to do. In the iOS app the
  // native composer takes drops instead.
  const drop = useFileDrop(attachments.add)
  const dropping = native ? { dragging: false, handlers: {} } : drop

  const send = (text: string) => {
    submit(text, attachments.ready)
    attachments.clear()
  }
  const parts: ChatParts = { session, transcript, busy, attachments, send, interrupt, rename }

  return (
    <ChatContext.Provider value={scope}>
      <div
        className={
          "chat @container flex min-h-0 min-w-0 flex-1 flex-col bg-background font-sans text-foreground" +
          (dropping.dragging ? " outline-1 -outline-offset-2 outline-primary outline-dashed" : "")
        }
        {...dropping.handlers}
      >
        {/* A band at the top rather than an overlay: an overlay over the
            transcript would hide what you are attaching the file to. */}
        {dropping.dragging && (
          <div className="shrink-0 bg-primary px-4 py-1 text-center text-sm text-primary-foreground">
            Drop to attach to this conversation
          </div>
        )}

        {header?.(parts)}

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

        {composer(parts)}
      </div>
    </ChatContext.Provider>
  )
}
