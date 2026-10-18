import type { OutputFile } from "./api"

/**
 * What the canvas is showing for one session: a path under its `output/`,
 * shown in a sandboxed iframe, and what its download button fetches — the
 * file itself, or for a page the whole directory as a zip.
 */
export type CanvasItem = {
  path: string
  title: string
  download: { kind: "file" | "dir"; path: string }
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
