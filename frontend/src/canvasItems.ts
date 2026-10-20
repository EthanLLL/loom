import type { AgentFile, OutputFile } from "./api"

/**
 * What the canvas is showing for one session: a path under its `output/` — or,
 * with `source: "files"`, the name of something the user attached — and what
 * its download button fetches: the file itself, or for a page the whole
 * directory as a zip.
 */
export type CanvasItem = {
  path: string
  title: string
  source?: "output" | "files"
  download: { kind: "file" | "dir" | "attachment"; path: string }
  // Changed to make the canvas read the file again: each time it is opened,
  // and when a turn rewrites what is on show. A file rewritten in place keeps
  // its path, so the path alone would go on showing the old version.
  rev?: number
}

/**
 * Whether a turn's outputs — top-level entries of `output/`, each a file or a
 * whole directory — include what `item` shows.
 */
export function touches(item: CanvasItem, changed: string[]): boolean {
  if (item.source === "files") return false
  return changed.some((path) => item.path === path || item.path.startsWith(path + "/"))
}

/**
 * What `item` becomes once `from` (a file or directory under `source`) is
 * renamed to `to`, or deleted (`to` null): the same item at its new path,
 * `null` when it went with the deletion, or `undefined` when it was not
 * affected at all.
 */
export function moved(
  item: CanvasItem,
  source: "output" | "files",
  from: string,
  to: string | null,
): CanvasItem | null | undefined {
  const under = (path: string) => path === from || path.startsWith(from + "/")
  if ((item.source ?? "output") !== source || !under(item.path)) return undefined
  if (to === null) return null
  const move = (path: string) => (under(path) ? to + path.slice(from.length) : path)
  return {
    ...item,
    path: move(item.path),
    title: move(item.title),
    download: { ...item.download, path: move(item.download.path) },
  }
}

// What the canvas can show rather than download, by how it shows it: loom's
// own viewers for images, media, markdown, tables and text, and a sandboxed
// iframe for pages and PDFs, which the browser renders itself. Anything else
// downloads on click.
export type Viewer = "image" | "video" | "audio" | "markdown" | "table" | "text" | "frame"

const VIEWERS: Record<Viewer, string> = {
  image: "png jpg jpeg gif webp svg avif bmp ico",
  video: "mp4 webm mov m4v ogv",
  audio: "mp3 wav ogg oga m4a flac aac opus",
  markdown: "md markdown",
  table: "csv tsv",
  text:
    "json txt log jsonl ndjson yaml yml toml ini conf xml " +
    "py rb go rs java kt c h cc cpp hpp cs swift ex exs erl sh bash zsh fish ts tsx jsx js css sql lua r diff patch",
  frame: "html htm pdf",
}

const BY_EXT = new Map(
  (Object.entries(VIEWERS) as [Viewer, string][]).flatMap(([viewer, exts]) =>
    exts.split(" ").map((ext) => [ext, viewer] as const),
  ),
)

export function viewerFor(path: string): Viewer | null {
  const name = path.split("/").pop() ?? path
  const dot = name.lastIndexOf(".")
  return dot > 0 ? (BY_EXT.get(name.slice(dot + 1).toLowerCase()) ?? null) : null
}

export function previewable(path: string): boolean {
  return viewerFor(path) !== null
}

/** A file under `output/` to show, or `null` if it can only be downloaded. */
export function itemForPath(path: string): CanvasItem | null {
  if (!previewable(path)) return null
  // A page one directory down downloads as that directory, assets included.
  const parts = path.split("/")
  const page = parts.length === 2 && parts[1] === "index.html"
  return {
    path,
    title: page ? parts[0] : path,
    download: page ? { kind: "dir", path: parts[0] } : { kind: "file", path },
  }
}

/**
 * What clicking an output card opens: a directory with an `index.html` is a
 * page, a previewable file is itself, and anything else is `null` — downloaded
 * instead (a directory without a page, as a zip).
 */
export function itemForOutput(entry: OutputFile): CanvasItem | null {
  if (entry.kind === "dir") {
    return entry.index
      ? { path: entry.index, title: entry.path, download: { kind: "dir", path: entry.path } }
      : null
  }
  return itemForPath(entry.path)
}

/** An attachment to show, by its stored name, or `null` if it can only be downloaded. */
export function itemForAttachment(file: AgentFile): CanvasItem | null {
  const name = file.path.split("/").pop() ?? file.path
  if (!previewable(name)) return null
  return { path: name, title: file.name, source: "files", download: { kind: "attachment", path: name } }
}
