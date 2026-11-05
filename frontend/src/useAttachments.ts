import { useCallback, useRef, useState, useSyncExternalStore } from "react"
import { attachmentUrl, blobUrl, isThumbnail, seedBlobUrl, uploadAgentFiles, type AgentFile } from "./api"
import { shrinkImage } from "./shrink"

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
  type: string
  // An image shown from the local copy, so the thumbnail is there before the
  // upload finishes.
  preview: string | null
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

// ── The trays, one per session, outside any component ───────────────────
//
// Switching sessions rebuilds the chat, and what was attached but not sent
// has to be there on the way back, like the draft text is. So the trays live
// here, and an upload still running when the chat goes away lands in its
// tray all the same. Per session, too, because the files live under the
// session that owns them and the server refuses a path from anywhere else.
//
// The uploaded ones are also kept in localStorage, so a reload keeps them;
// their thumbnails are read back from the server.

const EMPTY: Attachment[] = []
const trays = new Map<string, Attachment[]>()
const listeners = new Set<() => void>()
const storeKey = (sessionId: string) => `loom_attach:${sessionId}`
let nextKey = 0

type Kept = { name: string; size: number; type: string; file: AgentFile }

function tray(sessionId: string): Attachment[] {
  let items = trays.get(sessionId)
  if (items === undefined) {
    items = restore(sessionId)
    trays.set(sessionId, items)
  }
  return items
}

function update(sessionId: string, change: (items: Attachment[]) => Attachment[]) {
  const items = change(tray(sessionId))
  trays.set(sessionId, items)
  const kept: Kept[] = items.flatMap((i) =>
    i.file && !i.error ? [{ name: i.name, size: i.size, type: i.type, file: i.file }] : [],
  )
  if (kept.length === 0) localStorage.removeItem(storeKey(sessionId))
  else localStorage.setItem(storeKey(sessionId), JSON.stringify(kept))
  listeners.forEach((listener) => listener())
}

function restore(sessionId: string): Attachment[] {
  let kept: Kept[] = []
  try {
    kept = JSON.parse(localStorage.getItem(storeKey(sessionId)) ?? "[]")
  } catch {
    return []
  }
  return kept.map((k) => {
    const key = `a${nextKey++}`
    if (isThumbnail(k.type)) {
      blobUrl(attachmentUrl(sessionId, k.file.path))
        .then((preview) => patch(sessionId, key, { preview }))
        .catch(() => {})
    }
    return { key, name: k.name, size: k.size, type: k.type, preview: null, file: k.file, error: null }
  })
}

function patch(sessionId: string, key: string, change: Partial<Attachment>) {
  update(sessionId, (items) => items.map((item) => (item.key === key ? { ...item, ...change } : item)))
}

const subscribe = (listener: () => void) => {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

export function useAttachments(sessionId: string | null): Attachments {
  const items = useSyncExternalStore(subscribe, () => (sessionId ? tray(sessionId) : EMPTY))

  const add = useCallback(
    (files: File[]) => {
      if (!sessionId || files.length === 0) return

      const rows: Attachment[] = files.map((file) => ({
        key: `a${nextKey++}`,
        name: file.name,
        size: file.size,
        type: file.type,
        preview: isThumbnail(file.type) ? URL.createObjectURL(file) : null,
        file: null,
        error: null,
      }))
      update(sessionId, (prev) => [...prev, ...rows])

      // One request per file: the server stores a request all-or-nothing, so
      // batching would let an oversized fourth file void three good ones.
      // An image is scaled down first; see shrink.ts.
      files.forEach((file, i) => {
        shrinkImage(file)
          .then((small) => {
            if (small !== file) patch(sessionId, rows[i].key, { name: small.name, size: small.size })
            return uploadAgentFiles(sessionId, [small])
          })
          .then(([stored]) => {
            // The sent bubble will ask for this file by its server URL; it can
            // have the local copy instead. Never revoked for the same reason.
            const preview = rows[i].preview
            if (stored && preview) seedBlobUrl(attachmentUrl(sessionId, stored.path), preview)
            patch(sessionId, rows[i].key, stored ? { file: stored } : { error: "not stored" })
          })
          .catch((e: unknown) =>
            patch(sessionId, rows[i].key, {
              error: e instanceof Error ? e.message : "upload failed",
            }),
          )
      })
    },
    [sessionId],
  )

  const remove = useCallback(
    (key: string) => {
      // Only dropped from the tray. The file stays on disk under the session,
      // which is harmless — nothing reads it unless a message names it — and
      // deleting it would need a path from the client, which is exactly the
      // input we refuse to trust elsewhere.
      if (sessionId) update(sessionId, (prev) => prev.filter((item) => item.key !== key))
    },
    [sessionId],
  )

  const clear = useCallback(() => {
    if (sessionId) update(sessionId, () => [])
  }, [sessionId])

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
