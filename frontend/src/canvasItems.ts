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

// What the browser shows inside an iframe instead of downloading. The server
// sends the text group as text/plain, so a log or a .py displays too; see
// `LoomWeb.CanvasController`. Anything else downloads on click.
const PREVIEW = new Set(
  [
    "html htm",
    "png jpg jpeg gif webp svg avif bmp ico",
    "mp4 webm mov m4v ogv mp3 wav ogg oga m4a flac aac opus",
    "pdf",
    "json md markdown txt log csv tsv jsonl ndjson yaml yml toml ini conf xml",
    "py rb go rs java kt c h cc cpp hpp cs swift ex exs erl sh bash zsh fish ts tsx jsx js css sql lua r diff patch",
  ]
    .join(" ")
    .split(" "),
)

export function previewable(path: string): boolean {
  const name = path.split("/").pop() ?? path
  const dot = name.lastIndexOf(".")
  return dot > 0 && PREVIEW.has(name.slice(dot + 1).toLowerCase())
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
