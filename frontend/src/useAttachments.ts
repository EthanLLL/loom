import { useCallback, useEffect, useRef, useState } from "react"
import { uploadAgentFiles, type AgentFile } from "./api"

/**
 * One row in the composer's attachment tray.
 *
 * The upload starts the moment a file is picked, dropped or pasted — not on
 * send. So a 413 or a dead connection shows up while the user is still looking
 * at the composer and can do something about it, and pressing send stays
 * instant no matter how big the file was.
 */
export type Attachment = {
  key: string
  name: string
  size: number
  // Set once the server has the file; `null` means still uploading.
  file: AgentFile | null
  error: string | null
}

export type Attachments = {
  items: Attachment[]
  /** Files whose upload finished — the ones a submit can carry. */
  ready: AgentFile[]
  uploading: boolean
  add: (files: File[]) => void
  remove: (key: string) => void
  clear: () => void
}

export function useAttachments(sessionId: string | null): Attachments {
  const [items, setItems] = useState<Attachment[]>([])
  const nextKey = useRef(0)

  // Switching session must not carry one conversation's attachments into
  // another: the files live under the session that owns them, and the server
  // refuses a path from anywhere else.
  useEffect(() => setItems([]), [sessionId])

  const patch = useCallback((key: string, change: Partial<Attachment>) => {
    setItems((prev) =>
      prev.map((item) => (item.key === key ? { ...item, ...change } : item)),
    )
  }, [])

  const add = useCallback(
    (files: File[]) => {
      if (!sessionId || files.length === 0) return

      const rows: Attachment[] = files.map((file) => ({
        key: `a${nextKey.current++}`,
        name: file.name,
        size: file.size,
        file: null,
        error: null,
      }))
      setItems((prev) => [...prev, ...rows])

      // One request per file: the server stores a request all-or-nothing, so
      // batching would let an oversized fourth file void three good ones.
      files.forEach((file, i) => {
        uploadAgentFiles(sessionId, [file])
          .then(([stored]) =>
            patch(rows[i].key, stored ? { file: stored } : { error: "not stored" }),
          )
          .catch((e: unknown) =>
            patch(rows[i].key, {
              error: e instanceof Error ? e.message : "upload failed",
            }),
          )
      })
    },
    [sessionId, patch],
  )

  const remove = useCallback((key: string) => {
    // Only dropped from the tray. The file stays on disk under the session,
    // which is harmless — nothing reads it unless a message names it — and
    // deleting it would need a path from the client, which is exactly the
    // input we refuse to trust elsewhere.
    setItems((prev) => prev.filter((item) => item.key !== key))
  }, [])

  const clear = useCallback(() => setItems([]), [])

  return {
    items,
    ready: items.flatMap((item) => (item.file ? [item.file] : [])),
    uploading: items.some((item) => !item.file && !item.error),
    add,
    remove,
    clear,
  }
}

/**
 * Drag-and-drop onto a whole region.
 *
 * `dragEnter`/`dragLeave` fire for every child element the pointer crosses, so
 * the depth counter is what keeps the highlight from flickering off as the file
 * moves over a message bubble.
 */
export function useFileDrop(onFiles: (files: File[]) => void) {
  const [dragging, setDragging] = useState(false)
  const depth = useRef(0)

  const handlers = {
    onDragEnter: (e: React.DragEvent) => {
      if (!hasFiles(e)) return
      depth.current += 1
      setDragging(true)
    },
    onDragOver: (e: React.DragEvent) => {
      if (!hasFiles(e)) return
      // Without preventDefault the browser refuses the drop and opens the file
      // in a new tab instead.
      e.preventDefault()
      e.dataTransfer.dropEffect = "copy"
    },
    onDragLeave: (e: React.DragEvent) => {
      if (!hasFiles(e)) return
      depth.current = Math.max(0, depth.current - 1)
      if (depth.current === 0) setDragging(false)
    },
    onDrop: (e: React.DragEvent) => {
      if (!hasFiles(e)) return
      e.preventDefault()
      depth.current = 0
      setDragging(false)
      onFiles(Array.from(e.dataTransfer.files))
    },
  }

  return { dragging, handlers }
}

// Dragged text and dragged links also raise these events; only a file drag is
// ours to take.
function hasFiles(e: React.DragEvent): boolean {
  return Array.from(e.dataTransfer.types).includes("Files")
}
