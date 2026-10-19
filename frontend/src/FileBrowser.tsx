import {
  AppWindow,
  ChevronDown,
  ChevronRight,
  Download,
  File as FileIcon,
  FileCode,
  FileImage,
  FileMusic,
  FileSpreadsheet,
  FileText,
  FileVideo,
  Folder,
  FolderOpen,
  type LucideIcon,
} from "lucide-react"
import { useEffect, useMemo, useState, type ReactNode } from "react"
import {
  downloadAgentOutput,
  downloadAgentZip,
  downloadAttachment,
  sessionTree,
  type TreeFile,
} from "./api"
import { itemForAttachment, itemForPath, viewerFor, type CanvasItem, type Viewer } from "./canvasItems"
import { formatBytes } from "./format"

type Section = "output" | "files"

type Node = {
  name: string
  path: string
  size: number
  // The newest file at or under it, which is what a directory sorts by.
  mtime: number
  // Directories only.
  children?: Node[]
}

/**
 * Everything one session holds, as two trees: what the agent made (`output/`)
 * and what the user attached (`files/`). The cards in the chat only announce
 * what each turn changed; this is where last week's report is found again.
 *
 * Newest first at every level, like the chat itself. Clicking a file opens it
 * in the canvas when there is a viewer for it and downloads it otherwise; a
 * directory folds open, and offers its page (if it has an `index.html`) and a
 * zip of itself.
 *
 * Listed when shown and again whenever `rev` moves — the session bumps it when
 * a turn leaves outputs or a message brings attachments — rather than polled.
 */
export function FileBrowser({
  sessionId,
  rev,
  onOpen,
}: {
  sessionId: string
  rev: number
  onOpen: (item: CanvasItem) => void
}) {
  const [tree, setTree] = useState<{ files: TreeFile[]; output: TreeFile[] } | null>(null)
  const [error, setError] = useState<string | null>(null)
  // Unfolded directories, as `section:path`.
  const [unfolded, setUnfolded] = useState<Set<string>>(() => new Set())

  useEffect(() => {
    let live = true
    sessionTree(sessionId).then(
      (t) => {
        if (!live) return
        setTree(t)
        setError(null)
      },
      (e: Error) => live && setError(e.message),
    )
    return () => {
      live = false
    }
  }, [sessionId, rev])

  const output = useMemo(() => (tree ? build(tree.output) : []), [tree])
  const files = useMemo(() => (tree ? build(tree.files) : []), [tree])

  const fail = (e: Error) => setError(e.message)

  const open = (section: Section, node: Node) => {
    if (node.children) {
      const key = `${section}:${node.path}`
      setUnfolded((s) => {
        const next = new Set(s)
        if (!next.delete(key)) next.add(key)
        return next
      })
      return
    }
    const item =
      section === "output"
        ? itemForPath(node.path)
        : itemForAttachment({ name: node.name, path: node.path, size: node.size, content_type: "" })
    if (item) onOpen(item)
    else download(section, node)
  }

  const download = (section: Section, node: Node) => {
    const done =
      section === "files"
        ? downloadAttachment(sessionId, node.path)
        : node.children
          ? downloadAgentZip(sessionId, node.path)
          : downloadAgentOutput(sessionId, node.path)
    done.catch(fail)
  }

  const rows = (section: Section, nodes: Node[], depth: number): ReactNode[] =>
    nodes.flatMap((node) => {
      const isDir = !!node.children
      const unfoldedHere = isDir && unfolded.has(`${section}:${node.path}`)
      const page = isDir && node.children!.some((c) => c.name === "index.html" && !c.children)
      const Icon = isDir ? (unfoldedHere ? FolderOpen : Folder) : iconFor(node.name)
      const row = (
        <div
          key={`${section}:${node.path}`}
          className="tree-row"
          style={{ paddingLeft: `${0.5 + depth * 1}rem` }}
          onClick={() => open(section, node)}
          title={node.path}
        >
          <span className="tree-fold">
            {isDir && (unfoldedHere ? <ChevronDown /> : <ChevronRight />)}
          </span>
          <Icon className="tree-icon" />
          <span className="tree-name">{node.name}</span>
          <span className="tree-meta">
            {formatBytes(node.size)} · {formatTime(node.mtime)}
          </span>
          <span className="tree-actions">
            {page && (
              <button
                className="pane-btn"
                title={`Show ${node.path} in the canvas`}
                onClick={(e) => {
                  e.stopPropagation()
                  onOpen({
                    path: `${node.path}/index.html`,
                    title: node.path,
                    download: { kind: "dir", path: node.path },
                  })
                }}
              >
                <AppWindow />
              </button>
            )}
            <button
              className="pane-btn download"
              title={isDir ? `Download ${node.path} as a zip` : `Download ${node.name}`}
              onClick={(e) => {
                e.stopPropagation()
                download(section, node)
              }}
            >
              <Download />
            </button>
          </span>
        </div>
      )
      return unfoldedHere ? [row, ...rows(section, node.children!, depth + 1)] : [row]
    })

  return (
    <div className="file-browser">
      {error && <div className="canvas-note failed">{error}</div>}
      {!tree && !error && <div className="canvas-note">loading…</div>}
      {tree && (
        <>
          <div className="tree-section">Output</div>
          {output.length ? (
            rows("output", output, 0)
          ) : (
            <div className="tree-empty">Nothing made in this session yet.</div>
          )}
          <div className="tree-section">Uploads</div>
          {files.length ? (
            rows("files", files, 0)
          ) : (
            <div className="tree-empty">Nothing attached in this session yet.</div>
          )}
        </>
      )}
    </div>
  )
}

/** Flat paths into a tree, each level newest first. */
function build(list: TreeFile[]): Node[] {
  const root: Node = { name: "", path: "", size: 0, mtime: 0, children: [] }
  for (const file of list) {
    const parts = file.path.split("/")
    let dir = root
    parts.forEach((name, i) => {
      dir.size += file.size
      dir.mtime = Math.max(dir.mtime, file.mtime)
      const path = parts.slice(0, i + 1).join("/")
      if (i === parts.length - 1) {
        dir.children!.push({ name, path, size: file.size, mtime: file.mtime })
        return
      }
      let next = dir.children!.find((c) => c.children && c.name === name)
      if (!next) {
        next = { name, path, size: 0, mtime: 0, children: [] }
        dir.children!.push(next)
      }
      dir = next
    })
  }
  const sort = (nodes: Node[]) => {
    nodes.sort((a, b) => b.mtime - a.mtime || a.name.localeCompare(b.name))
    for (const n of nodes) if (n.children) sort(n.children)
  }
  sort(root.children!)
  return root.children!
}

const ICONS: Record<Viewer, LucideIcon> = {
  image: FileImage,
  video: FileVideo,
  audio: FileMusic,
  markdown: FileText,
  table: FileSpreadsheet,
  text: FileCode,
  frame: AppWindow,
}

function iconFor(name: string): LucideIcon {
  if (/\.(xlsx?|numbers)$/i.test(name)) return FileSpreadsheet
  if (/\.(docx?|pdf|pptx?|key)$/i.test(name)) return FileText
  const viewer = viewerFor(name)
  return viewer ? ICONS[viewer] : FileIcon
}

// Time of day for today, the date otherwise, with the year only when it is not this one.
function formatTime(seconds: number): string {
  const d = new Date(seconds * 1000)
  const now = new Date()
  if (d.toDateString() === now.toDateString()) {
    return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
  }
  return d.toLocaleDateString([], {
    month: "numeric",
    day: "numeric",
    ...(d.getFullYear() !== now.getFullYear() && { year: "numeric" }),
  })
}
