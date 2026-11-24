import { ArrowDown01Icon, ArrowRight01Icon, BrowserIcon, Download04Icon, File01Icon, FileScriptIcon, FileTextIcon, Folder01Icon, FolderOpenIcon, Image01Icon, MoreHorizontalIcon, MusicNote01Icon, Video01Icon, Xls01Icon } from "@hugeicons/core-free-icons"
import { HugeiconsIcon, type IconSvgElement } from "@hugeicons/react"
import { useEffect, useMemo, useState, type ReactNode } from "react"
import {
  deleteAgentOutputOrAttachment,
  downloadAgentOutput,
  downloadAgentZip,
  downloadAttachment,
  renameAgentOutputOrAttachment,
  sessionTree,
  type TreeFile,
} from "./api"
import { Button } from "@/components/ui/button"
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu"
import { Confirm, RenameInput } from "./Confirm"
import { itemForAttachment, itemForPath, viewerFor, type CanvasItem, type Viewer } from "./canvasItems"
import { formatBytes } from "./format"
import { PaneNote } from "./Pane"

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
 * Newest first at every level, like the chat itself. The row of what the
 * canvas is showing is marked; sizes and dates are in each row's tooltip, as
 * the tree is a narrow column. Clicking a file opens it
 * in the canvas when there is a viewer for it and downloads it otherwise; a
 * directory folds open, and offers its page (if it has an `index.html`) and a
 * zip of itself.
 *
 * Listed when shown and again whenever `rev` moves — the session bumps it when
 * a turn leaves outputs or a message brings attachments — rather than polled.
 *
 * A row's menu renames it or deletes it (after asking). Either one is
 * reported by `onMoved`, so the canvas can follow what it shows.
 */
export function FileBrowser({
  sessionId,
  rev,
  current,
  onOpen,
  onMoved,
}: {
  sessionId: string
  rev: number
  // What the canvas shows, as `source:path`, so its row can be marked.
  current: string | null
  onOpen: (item: CanvasItem) => void
  onMoved: (source: Section, from: string, to: string | null) => void
}) {
  const [tree, setTree] = useState<{ files: TreeFile[]; output: TreeFile[] } | null>(null)
  const [error, setError] = useState<string | null>(null)
  // Unfolded directories, as `section:path`.
  const [unfolded, setUnfolded] = useState<Set<string>>(() => new Set())
  // Listed again after a rename or a delete here, which no turn reports.
  const [changes, setChanges] = useState(0)
  // The row whose name is being edited, and the one waiting for a yes.
  const [renaming, setRenaming] = useState<string | null>(null)
  const [asking, setAsking] = useState<{ key: string; section: Section; node: Node } | null>(
    null,
  )

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
  }, [sessionId, rev, changes])

  const output = useMemo(() => (tree ? build(tree.output) : []), [tree])
  const files = useMemo(() => (tree ? build(tree.files) : []), [tree])

  const fail = (e: Error) => setError(e.message)

  const fold = (key: string, open: boolean) =>
    setUnfolded((s) => {
      const next = new Set(s)
      if (open) next.add(key)
      else next.delete(key)
      return next
    })

  const open = (section: Section, node: Node) => {
    if (node.children) {
      const key = `${section}:${node.path}`
      fold(key, !unfolded.has(key))
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

  const remove = async (section: Section, node: Node) => {
    const key = `${section}:${node.path}`
    await deleteAgentOutputOrAttachment(sessionId, section, node.path)
    setUnfolded((u) => new Set([...u].filter((k) => k !== key && !k.startsWith(key + "/"))))
    onMoved(section, node.path, null)
    setChanges((n) => n + 1)
  }

  const rename = async (section: Section, node: Node, name: string | null) => {
    if (name === null) return setRenaming(null)
    const { path } = await renameAgentOutputOrAttachment(sessionId, section, node.path, name)
    const from = `${section}:${node.path}`
    const to = `${section}:${path}`
    const move = (k: string) => (k === from || k.startsWith(from + "/") ? to + k.slice(from.length) : k)
    setUnfolded((s) => new Set([...s].map(move)))
    setRenaming(null)
    onMoved(section, node.path, path)
    setChanges((n) => n + 1)
  }

  const rows = (section: Section, nodes: Node[], depth: number): ReactNode[] =>
    nodes.flatMap((node) => {
      const isDir = !!node.children
      const unfoldedHere = isDir && unfolded.has(`${section}:${node.path}`)
      const page = isDir && node.children!.some((c) => c.name === "index.html" && !c.children)
      const icon = isDir ? (unfoldedHere ? FolderOpenIcon : Folder01Icon) : iconFor(node.name)
      // The row of what is shown, or the folded directory hiding it.
      const shown =
        current === `${section}:${node.path}` ||
        (isDir && !unfoldedHere && !!current?.startsWith(`${section}:${node.path}/`))
      const key = `${section}:${node.path}`
      const row = (
        <div
          key={key}
          className={
            "group/row mx-1.5 flex min-h-7.5 cursor-pointer items-center gap-1.5 rounded-md pr-1 hover:bg-muted pointer-coarse:min-h-[44px]" +
            (shown ? " bg-muted font-medium text-foreground" : "")
          }
          style={{ paddingLeft: `${0.25 + depth * 0.9}rem` }}
          onClick={() => open(section, node)}
          title={`${node.path}\n${formatBytes(node.size)} · ${formatTime(node.mtime)}`}
        >
          <span className="inline-flex w-4 shrink-0 text-muted-foreground">
            {isDir && <HugeiconsIcon icon={unfoldedHere ? ArrowDown01Icon : ArrowRight01Icon} />}
          </span>
          <HugeiconsIcon
            icon={icon}
            className={"shrink-0 " + (shown ? "text-foreground" : "text-muted-foreground")}
          />
          {renaming === key ? (
            <RenameInput value={node.name} onDone={(name) => rename(section, node, name)} />
          ) : (
            <span className="min-w-0 flex-1 truncate">{node.name}</span>
          )}
          {/* Shown on hover, where there is hover; always on a touch screen.
              Hidden rather than absent, so names do not shift under the
              pointer. */}
          <span className="invisible flex shrink-0 gap-0.5 group-hover/row:visible pointer-coarse:visible">
            {page && (
              <Button
                variant="ghost"
                size="icon-xs"
                className="text-muted-foreground"
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
                <HugeiconsIcon icon={BrowserIcon} />
              </Button>
            )}
            <Button
              variant="ghost"
              size="icon-xs"
              className="text-muted-foreground"
              title={isDir ? `Download ${node.path} as a zip` : `Download ${node.name}`}
              onClick={(e) => {
                e.stopPropagation()
                download(section, node)
              }}
            >
              <HugeiconsIcon icon={Download04Icon} />
            </Button>
            <DropdownMenu>
              <DropdownMenuTrigger
                render={<Button variant="ghost" size="icon-xs" className="text-muted-foreground" title="More" />}
                onClick={(e) => e.stopPropagation()}
              >
                <HugeiconsIcon icon={MoreHorizontalIcon} />
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end" className="w-36" onClick={(e) => e.stopPropagation()}>
                <DropdownMenuItem onClick={() => setRenaming(key)}>Rename</DropdownMenuItem>
                <DropdownMenuItem variant="destructive" onClick={() => setAsking({ key, section, node })}>
                  Delete
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </span>
        </div>
      )
      return unfoldedHere ? [row, ...rows(section, node.children!, depth + 1)] : [row]
    })

  return (
    <div className="absolute inset-0 overflow-auto pt-1 pb-8 font-sans text-sm pointer-coarse:text-base">
      {asking && (
        <Confirm
          title={`Delete ${asking.node.name}?`}
          detail={
            asking.node.children
              ? `The folder ${asking.node.path} and everything in it. This cannot be undone.`
              : `${asking.node.path} — this cannot be undone.`
          }
          onYes={() => remove(asking.section, asking.node)}
          onClose={() => setAsking(null)}
        />
      )}
      {error && <PaneNote failed>{error}</PaneNote>}
      {!tree && !error && <PaneNote>Loading…</PaneNote>}
      {tree && (
        <>
          <Heading>Output</Heading>
          {output.length ? rows("output", output, 0) : <Empty>Nothing made in this session yet.</Empty>}
          <Heading>Uploads</Heading>
          {files.length ? rows("files", files, 0) : <Empty>Nothing attached in this session yet.</Empty>}
        </>
      )}
    </div>
  )
}

// As the sidebar labels its groups.
function Heading({ children }: { children: ReactNode }) {
  return (
    <div className="px-3.5 pt-3 pb-1 text-xs font-medium text-muted-foreground pointer-coarse:text-[13px]">
      {children}
    </div>
  )
}

function Empty({ children }: { children: ReactNode }) {
  return <div className="px-3.5 py-1 text-xs text-muted-foreground pointer-coarse:text-[13px]">{children}</div>
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

const ICONS: Record<Viewer, IconSvgElement> = {
  image: Image01Icon,
  video: Video01Icon,
  audio: MusicNote01Icon,
  markdown: FileTextIcon,
  table: Xls01Icon,
  text: FileScriptIcon,
  frame: BrowserIcon,
}

function iconFor(name: string): IconSvgElement {
  if (/\.(xlsx?|numbers)$/i.test(name)) return Xls01Icon
  if (/\.(docx?|pdf|pptx?|key)$/i.test(name)) return FileTextIcon
  const viewer = viewerFor(name)
  return viewer ? ICONS[viewer] : File01Icon
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
