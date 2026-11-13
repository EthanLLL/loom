import { FileIcon, FolderIcon, GlobeIcon, LoaderCircleIcon, XIcon } from "lucide-react"
import { useEffect, useState, type ReactNode } from "react"
import {
  Attachment,
  AttachmentAction,
  AttachmentActions,
  AttachmentContent,
  AttachmentDescription,
  AttachmentMedia,
  AttachmentTitle,
  AttachmentTrigger,
} from "@/components/ui/attachment"
import {
  attachmentUrl,
  blobUrl,
  downloadAgentOutput,
  downloadAgentZip,
  downloadAttachment,
  isThumbnail,
  outputUrl,
  type AgentFile,
  type OutputFile,
} from "../api"
import { itemForAttachment, itemForOutput, itemForPath } from "../canvasItems"
import { formatBytes } from "../format"
import type { Attachment as Pending } from "../useAttachments"
import { useChat } from "./context"
import { extension } from "./format"

/**
 * One file as a small card: a thumbnail or an icon, its name, and what it is.
 * The same card everywhere a file appears — waiting in the composer, sent with
 * a message, or left by the agent for download — so a file looks the same on
 * its way in and on its way out.
 */
function FileCard({
  name,
  kind = "file",
  detail,
  image,
  busy = false,
  error,
  title,
  onClick,
  onRemove,
}: {
  name: string
  kind?: "file" | "dir" | "page"
  // Under the name: the extension and size, or why it failed.
  detail: string
  // Where the thumbnail comes from: a local object URL, or a promise of one
  // for a file behind the API token. `null` for anything not an image.
  image: string | Promise<string> | null
  busy?: boolean
  error?: string | null
  title: string
  onClick?: () => void
  onRemove?: () => void
}) {
  const [src, unreachable] = useResolved(image)
  // A format the browser cannot draw (HEIC, say), or a file that could not be
  // fetched, falls back to the plain card.
  const [broken, setBroken] = useState(false)
  const showImage = image !== null && !broken && !unreachable && src !== null
  const loading = busy || (image !== null && !broken && !unreachable && src === null && !error)
  const Icon = kind === "dir" ? FolderIcon : kind === "page" ? GlobeIcon : FileIcon

  return (
    <Attachment
      size="sm"
      state={error ? "error" : busy ? "uploading" : "done"}
      className="max-w-56 min-w-0"
      title={error ? `${name}: ${error}` : title}
    >
      {onClick && <AttachmentTrigger onClick={onClick} aria-label={title} />}
      <AttachmentMedia variant={showImage ? "image" : "icon"}>
        {loading ? (
          <LoaderCircleIcon className="animate-spin" />
        ) : showImage ? (
          <img src={src} alt="" onError={() => setBroken(true)} />
        ) : (
          <Icon />
        )}
      </AttachmentMedia>
      <AttachmentContent>
        <AttachmentTitle>{name}</AttachmentTitle>
        <AttachmentDescription>{error ?? detail}</AttachmentDescription>
      </AttachmentContent>
      {onRemove && (
        <AttachmentActions>
          <AttachmentAction aria-label={`Remove ${name}`} onClick={onRemove}>
            <XIcon />
          </AttachmentAction>
        </AttachmentActions>
      )}
    </Attachment>
  )
}

/** A thumbnail source, settled: `[src, failed]`, src `null` until it arrives. */
function useResolved(image: string | Promise<string> | null): [string | null, boolean] {
  const [state, setState] = useState<[string | null, boolean]>([
    typeof image === "string" ? image : null,
    false,
  ])

  useEffect(() => {
    if (image === null || typeof image === "string") {
      setState([image, false])
      return
    }
    let live = true
    setState([null, false])
    image.then(
      (url) => live && setState([url, false]),
      () => live && setState([null, true]),
    )
    return () => {
      live = false
    }
  }, [image])

  return state
}

function FileRow({ children }: { children: ReactNode }) {
  return <div className="flex flex-wrap gap-2">{children}</div>
}

type Fetch = "idle" | "busy" | { error: string }

/** The attachments that went out with a message. */
export function SentFiles({ files }: { files: AgentFile[] }) {
  return (
    <FileRow>
      {files.map((file) => (
        <SentFile key={file.path} file={file} />
      ))}
    </FileRow>
  )
}

/**
 * One sent attachment. Like an output, a click shows it in the canvas when the
 * browser can and downloads it otherwise.
 */
function SentFile({ file }: { file: AgentFile }) {
  const { sessionId, openCanvas } = useChat()
  const [state, setState] = useState<Fetch>("idle")
  const item = itemForAttachment(file)
  const stored = file.path.split("/").pop() ?? file.path

  const download = () => {
    if (state === "busy") return
    setState("busy")
    downloadAttachment(sessionId, stored).then(
      () => setState("idle"),
      (e: Error) => setState({ error: e.message }),
    )
  }

  return (
    <FileCard
      name={file.name}
      detail={`${extension(file.name)} · ${formatBytes(file.size)}`}
      image={isThumbnail(file.content_type) ? blobUrl(attachmentUrl(sessionId, file.path)) : null}
      busy={state === "busy"}
      error={typeof state === "object" ? state.error : null}
      title={`${item ? "Show" : "Download"} ${file.name} · ${formatBytes(file.size)}`}
      onClick={item ? () => openCanvas(item) : download}
    />
  )
}

/**
 * What a turn left in the output directory, one card per file.
 *
 * Comes from the server scanning the directory, not from the reply, so it is
 * here even when the model forgot to mention the file. See `Loom.Agent.Output`.
 */
export function OutputFiles({ files, more }: { files: OutputFile[]; more: number }) {
  return (
    <FileRow>
      {files.map((file) => (
        <OutputCard key={file.path} file={file} />
      ))}
      {more > 0 && (
        <span className="self-center px-2 text-sm text-muted-foreground">+{more} more</span>
      )}
    </FileRow>
  )
}

/**
 * One output. A click shows it in the canvas when the browser can (a page, an
 * image, a video, a PDF, text), and downloads it otherwise; a directory with no
 * page downloads as a zip. The canvas has its own download button.
 */
function OutputCard({ file }: { file: OutputFile }) {
  const { sessionId, openCanvas } = useChat()
  const [state, setState] = useState<Fetch>("idle")
  const dir = file.kind === "dir"
  const name = file.path.split("/").pop() ?? file.path
  const item = itemForOutput(file)

  const download = () => {
    if (state === "busy") return
    setState("busy")
    ;(dir ? downloadAgentZip(sessionId, file.path) : downloadAgentOutput(sessionId, file.path)).then(
      () => setState("idle"),
      (e: Error) => setState({ error: e.message }),
    )
  }

  const size = formatBytes(file.size)
  const what = dir ? `${file.files} file${file.files === 1 ? "" : "s"} · ${size}` : size
  const kind = dir ? (file.index ? "page" : "dir") : "file"

  return (
    <FileCard
      name={name}
      kind={kind}
      detail={
        (kind === "page" ? "Page" : kind === "dir" ? "Folder" : extension(name)) +
        ` · ${what}` +
        (file.updated ? " · updated" : "")
      }
      image={!dir && isThumbnail(file.content_type) ? blobUrl(outputUrl(sessionId, file.path)) : null}
      busy={state === "busy"}
      error={typeof state === "object" ? state.error : null}
      title={`${item ? "Show" : dir ? "Download as a zip:" : "Download"} ${file.path} · ${what}`}
      onClick={item ? () => openCanvas(item) : download}
    />
  )
}

/**
 * One pending attachment: uploading, failed, or ready to go. Once the server
 * has it, a click shows it in the canvas, as it will be once sent.
 */
export function AttachmentChip({ item, onRemove }: { item: Pending; onRemove: () => void }) {
  const { openCanvas } = useChat()
  const shown = item.file ? itemForAttachment(item.file) : null

  return (
    <FileCard
      name={item.name}
      detail={`${extension(item.name)} · ${formatBytes(item.size)}`}
      image={item.preview}
      busy={!item.file && !item.error}
      error={item.error}
      title={`${shown ? "Show " : ""}${item.name} · ${formatBytes(item.size)}`}
      onClick={shown ? () => openCanvas(shown) : undefined}
      onRemove={onRemove}
    />
  )
}

// Reads as a link inside prose, so it does not break the line.
const linkStyle =
  "inline cursor-pointer text-primary underline decoration-primary/40 underline-offset-2 hover:decoration-primary"

/**
 * A link to one of the session's outputs, from inside a reply: shown in the
 * canvas when the browser can, fetched as a download otherwise.
 */
export function OutputLink({ path, label }: { path: string; label: ReactNode }) {
  const { sessionId, openCanvas } = useChat()
  const item = itemForPath(path)
  if (item) {
    return (
      <button type="button" className={linkStyle} title={`Show ${path}`} onClick={() => openCanvas(item)}>
        {label}
      </button>
    )
  }
  return <DownloadLink sessionId={sessionId} path={path} label={label} />
}

/**
 * A button that fetches one output and hands it to the browser as a download.
 *
 * A button, not a link: the file is behind the API token. The label stays put
 * while it downloads and the failure, if any, follows it — a file deleted
 * since the turn is the usual one.
 */
function DownloadLink({ sessionId, path, label }: { sessionId: string; path: string; label: ReactNode }) {
  const [state, setState] = useState<Fetch>("idle")

  const start = () => {
    if (state === "busy") return
    setState("busy")
    downloadAgentOutput(sessionId, path).then(
      () => setState("idle"),
      (e: Error) => setState({ error: e.message }),
    )
  }

  const failed = typeof state === "object"
  return (
    <button
      type="button"
      className={
        linkStyle +
        (state === "busy" ? " cursor-progress opacity-60" : "") +
        (failed ? " text-destructive" : "")
      }
      title={failed ? state.error : `Download ${path}`}
      onClick={start}
    >
      {label}
      {failed && <span className="ml-1 text-xs">{state.error}</span>}
    </button>
  )
}
