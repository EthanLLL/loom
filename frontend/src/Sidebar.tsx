import {
  ArrowDown01Icon,
  DashboardSquare01Icon,
  Delete02Icon,
  Folder01Icon,
  FolderAddIcon,
  FolderExportIcon,
  FolderOpenIcon,
  FolderRemoveIcon,
  Globe02Icon,
  MoreHorizontalIcon,
  PlusSignIcon,
  Search01Icon,
  Settings01Icon,
} from "@hugeicons/core-free-icons"
import { HugeiconsIcon } from "@hugeicons/react"
import { useEffect, useState } from "react"
import { Button } from "@/components/ui/button"
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuGroup,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import {
  Sidebar as Bar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuAction,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarMenuSub,
  useSidebar,
} from "@/components/ui/sidebar"
import type { AgentBackend, AgentInfo, Device } from "./api"
import { listProfiles } from "./api"
import { RenameInput } from "./Confirm"
import { filed, ROOT } from "./directories"
import { ago } from "./format"
import { isComposing } from "./ime"
import { dirName } from "./MovePicker"
import type { Push } from "./push"
import { SettingsDialog } from "./Settings"
import { useDragOrder } from "./useDragOrder"
import { lastActive } from "./useLobby"

// The directories unfolded in the sidebar, and whether the section itself is
// (it starts folded), on this device.
const UNFOLDED_KEY = "loom.unfolded"
const DIRS_OPEN_KEY = "loom.dirsOpen"

type Props = {
  sessions: AgentInfo[]
  devices: Device[]
  onUpsertDevice: (device: Device) => void
  push: Push
  // Desktop only, so null on a phone; see keys.tsx.
  vim: { on: boolean; toggle: () => void } | null
  activeId: string | null
  // The session under the keyboard's cursor while the list is walked; see App.
  cursorId: string | null
  // The session whose name is being edited in its row, and where it goes.
  renamingId: string | null
  onRenamed: (id: string, title: string | null) => Promise<void>
  onSelect: (id: string) => void
  onCreate: (backend: AgentBackend, profile?: string) => void
  onDelete: (id: string) => void
  // A phone's "Move to directory": the picker over everything. A desktop moves
  // from the menu's own submenu, straight to `onMoveTo`.
  onMove: (id: string) => void
  onMoveTo: (id: string, directory: string) => Promise<void>
  onRenameDirectory: (from: string, to: string) => Promise<void>
  // The directories' order, shared by every device; a drag sends a new one.
  directoryOrder: string[]
  onOrderDirectories: (order: string[]) => void
  narrow: boolean
  onSearch: () => void
  browserOpen: boolean
  onToggleBrowser: () => void
  appsOpen: boolean
  onToggleApps: () => void
}

/**
 * The session list, as a card floating beside the conversation (a drawer on a
 * phone): making one at the top, the directories and Recents under it, and the
 * ways out to the apps, the browser and the settings at the foot. It is opened
 * and closed from the conversation's bar.
 */
export function Sidebar({
  sessions,
  devices,
  onUpsertDevice,
  push,
  vim,
  activeId,
  cursorId,
  renamingId,
  onRenamed,
  onSelect,
  onCreate,
  onDelete,
  onMove,
  onMoveTo,
  onRenameDirectory,
  directoryOrder,
  onOrderDirectories,
  narrow,
  onSearch,
  browserOpen,
  onToggleBrowser,
  appsOpen,
  onToggleApps,
}: Props) {
  // Ages are relative, so they go stale without any new data. A local clock,
  // not a poll: nothing is fetched.
  const [, setNow] = useState(0)
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 30_000)
    return () => clearInterval(timer)
  }, [])
  const [settingsOpen, setSettingsOpen] = useState(false)
  // Directories first, in the order dragged into, each folded or unfolded as
  // last left on this device; then Recents, what is in none. The sessions in a
  // directory go by activity, like Recents; only the directories are dragged.
  const dirs = filed(sessions, directoryOrder)
  const drag = useDragOrder(dirs, onOrderDirectories)
  const root = sessions.filter((s) => (s.directory ?? ROOT) === ROOT)
  const [unfolded, setUnfolded] = useState<string[]>(() => {
    try {
      return JSON.parse(localStorage.getItem(UNFOLDED_KEY) ?? "[]") as string[]
    } catch {
      return []
    }
  })
  useEffect(() => localStorage.setItem(UNFOLDED_KEY, JSON.stringify(unfolded)), [unfolded])
  const [dirsOpen, setDirsOpen] = useState(() => localStorage.getItem(DIRS_OPEN_KEY) === "1")
  useEffect(() => localStorage.setItem(DIRS_OPEN_KEY, dirsOpen ? "1" : "0"), [dirsOpen])
  const fold = (dir: string) =>
    setUnfolded((open) => (open.includes(dir) ? open.filter((d) => d !== dir) : [...open, dir]))
  const [renamingDir, setRenamingDir] = useState<string | null>(null)
  const renameDir = async (from: string, name: string | null) => {
    setRenamingDir(null)
    const to = name === null ? "" : dirName(name)
    if (to === "" || to === from) return
    await onRenameDirectory(from, to)
    setUnfolded((open) => open.map((d) => (d === from ? to : d)))
  }

  const row = (s: AgentInfo) => (
    <SessionRow
      key={s.id}
      session={s}
      active={s.id === activeId}
      cursor={s.id === cursorId}
      renaming={s.id === renamingId}
      dirs={dirs}
      narrow={narrow}
      onRenamed={(title) => onRenamed(s.id, title)}
      onSelect={() => onSelect(s.id)}
      onDelete={() => onDelete(s.id)}
      onMove={() => onMove(s.id)}
      onMoveTo={(dir) => onMoveTo(s.id, dir)}
    />
  )

  return (
    <Bar variant="floating">
      {/* The top row is the conversation bar's height, so the two line up
          across the window. On a touch screen everything sits further in
          from the card's edge, clear of its round corners. */}
      <SidebarHeader className="sidebar-head gap-1 pt-0 sm:pointer-coarse:px-3">
        <div className="flex h-[44px] items-center justify-between border-b border-transparent pl-2 sm:h-(--head-h)">
          <span className="text-sm font-semibold tracking-tight pointer-coarse:text-[17px]">Loom</span>
          <Button
            variant="ghost"
            size="icon-sm"
            className="text-muted-foreground pointer-coarse:size-[48px]"
            onClick={onSearch}
            title={vim?.on ? "Search (␣␣)" : "Search"}
            aria-label="Search"
          >
            <HugeiconsIcon icon={Search01Icon} />
          </Button>
        </div>
        <SidebarMenu>
          <NewChat onCreate={onCreate} />
        </SidebarMenu>
      </SidebarHeader>

      <SidebarContent>
        {dirs.length > 0 && (
          <Collapsible open={dirsOpen} onOpenChange={setDirsOpen}>
            <SidebarGroup className="py-0 sm:pointer-coarse:px-3">
              <SidebarGroupLabel
                render={<CollapsibleTrigger />}
                className="group/label w-full hover:text-sidebar-foreground"
              >
                Directories
                <HugeiconsIcon
                  icon={ArrowDown01Icon}
                  className="ml-auto -rotate-90 transition-transform group-data-[panel-open]/label:rotate-0"
                />
              </SidebarGroupLabel>
              <CollapsibleContent>
                <SidebarGroupContent>
                  <SidebarMenu>
                    {drag.order.map((d) => {
                      const open = unfolded.includes(d)
                      const here = sessions
                        .filter((s) => s.directory === d)
                        .sort((a, b) => lastActive(b) - lastActive(a))
                      return (
                        <SidebarMenuItem key={d} className={drag.dragging === d ? "opacity-60" : undefined}>
                          {renamingDir === d ? (
                            <div className="flex h-8 items-center gap-2 px-2">
                              <HugeiconsIcon icon={Folder01Icon} className="size-4 shrink-0" />
                              <RenameInput value={d} stem={false} onDone={(name) => renameDir(d, name)} />
                            </div>
                          ) : (
                            // Held and dragged into order, so a div: the drag
                            // ignores presses that start on a button.
                            <SidebarMenuButton
                              render={<div role="button" tabIndex={0} />}
                              ref={drag.row(d)}
                              className="cursor-default touch-pan-y select-none"
                              onPointerDown={drag.start(d)}
                              onContextMenu={(e) => e.preventDefault()}
                              onClick={() => drag.clicked() || fold(d)}
                            >
                              <HugeiconsIcon icon={open ? FolderOpenIcon : Folder01Icon} />
                              <span className="min-w-0 flex-1 truncate">{d}</span>
                              {!open && (
                                <span className="text-xs text-muted-foreground tabular-nums pointer-coarse:text-[13px]">
                                  {here.length}
                                </span>
                              )}
                            </SidebarMenuButton>
                          )}
                          <DropdownMenu>
                            <DropdownMenuTrigger render={<SidebarMenuAction showOnHover title="More" />}>
                              <HugeiconsIcon icon={MoreHorizontalIcon} />
                            </DropdownMenuTrigger>
                            <DropdownMenuContent align="start" side={narrow ? "bottom" : "right"} className="w-44">
                              <DropdownMenuItem onClick={() => setRenamingDir(d)}>Rename</DropdownMenuItem>
                            </DropdownMenuContent>
                          </DropdownMenu>
                          {open && here.length > 0 && (
                            <SidebarMenuSub className="mr-0 pr-0">{here.map(row)}</SidebarMenuSub>
                          )}
                        </SidebarMenuItem>
                      )
                    })}
                  </SidebarMenu>
                </SidebarGroupContent>
              </CollapsibleContent>
            </SidebarGroup>
          </Collapsible>
        )}

        <SidebarGroup className="sm:pointer-coarse:px-3">
          {dirs.length > 0 && <SidebarGroupLabel>Recents</SidebarGroupLabel>}
          <SidebarGroupContent>
            <SidebarMenu>{root.map(row)}</SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      </SidebarContent>

      <SidebarFooter className="sm:pointer-coarse:px-3 sm:pointer-coarse:pb-4">
        <SidebarMenu>
          {/* What the agents distilled into programs, in ~/apps/: no model runs
              when one is opened. */}
          <SidebarMenuItem>
            <SidebarMenuButton isActive={appsOpen} onClick={onToggleApps}>
              <HugeiconsIcon icon={DashboardSquare01Icon} />
              <span>Apps</span>
            </SidebarMenuButton>
          </SidebarMenuItem>
          {/* Loom's own browser, the one agents drive: taking it over is how a
              site gets logged in to once and stays logged in. */}
          <SidebarMenuItem>
            <SidebarMenuButton
              isActive={browserOpen}
              onClick={onToggleBrowser}
              title="Loom's browser: log in to a site, or get past a check for the agents"
            >
              <HugeiconsIcon icon={Globe02Icon} />
              <span>Browser</span>
            </SidebarMenuButton>
          </SidebarMenuItem>
          {/* This device's preferences, the user's machines, and how this
              Loom is signed in to. */}
          <SidebarMenuItem>
            <SidebarMenuButton onClick={() => setSettingsOpen(true)}>
              <HugeiconsIcon icon={Settings01Icon} />
              <span>Settings</span>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
        <SettingsDialog
          open={settingsOpen}
          onOpenChange={setSettingsOpen}
          push={push}
          vim={vim}
          devices={devices}
          onUpsertDevice={onUpsertDevice}
        />
      </SidebarFooter>
    </Bar>
  )
}

// A working session's name: grey with a light sweeping over it, as a running
// step is in the conversation. The sweep is lighter than the text, so on the
// full-strength text of a row it would not show at all.
export const WORKING = " text-muted-foreground shimmer"

/**
 * One session: its name, shimmering while its agent works (as the step under
 * way does in the conversation), anything queued, and how long ago it last
 * spoke; its menu at the end.
 */
function SessionRow({
  session: s,
  active,
  cursor,
  renaming,
  dirs,
  narrow,
  onRenamed,
  onSelect,
  onDelete,
  onMove,
  onMoveTo,
}: {
  session: AgentInfo
  active: boolean
  cursor: boolean
  renaming: boolean
  dirs: string[]
  narrow: boolean
  onRenamed: (title: string | null) => Promise<void>
  onSelect: () => void
  onDelete: () => void
  onMove: () => void
  onMoveTo: (dir: string) => Promise<void>
}) {
  const dir = s.directory ?? ROOT
  const working = s.status === "running" || s.status === "starting"
  const title = s.title ?? s.id

  return (
    <SidebarMenuItem ref={cursor ? (el) => el?.scrollIntoView({ block: "nearest" }) : undefined}>
      {renaming ? (
        <div className="flex h-8 items-center px-2 pointer-coarse:h-[44px]">
          <RenameInput value={title} stem={false} onDone={onRenamed} />
        </div>
      ) : (
        <SidebarMenuButton
          isActive={active}
          onClick={onSelect}
          // Walking the list with j/k; see the keys in App.tsx.
          className={cursor ? "ring-2 ring-sidebar-ring" : undefined}
        >
          <span className={"min-w-0 flex-1 truncate" + (working ? WORKING : "")} title={s.status}>
            {title}
          </span>
          {s.queued > 0 && (
            <span
              className="rounded-full bg-sidebar-primary px-1.5 text-[0.625rem] leading-4 font-semibold text-sidebar-primary-foreground tabular-nums"
              title="queued messages"
            >
              {s.queued}
            </span>
          )}
          <span
            className="text-xs text-muted-foreground tabular-nums pointer-coarse:text-[13px]"
            title={"last active " + new Date(lastActive(s)).toLocaleString()}
          >
            {ago(lastActive(s))}
          </span>
        </SidebarMenuButton>
      )}

      <DropdownMenu>
        <DropdownMenuTrigger render={<SidebarMenuAction showOnHover title="More" />}>
          <HugeiconsIcon icon={MoreHorizontalIcon} />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="start" side={narrow ? "bottom" : "right"} className="w-52">
          <DropdownMenuItem variant="destructive" onClick={onDelete}>
            <HugeiconsIcon icon={Delete02Icon} />
            Delete
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          {/* Where it is, over what moves it; a label needs a group round it. */}
          <DropdownMenuGroup>
            {dir !== ROOT && <DropdownMenuLabel className="truncate">{dir}</DropdownMenuLabel>}
            {narrow ? (
              <DropdownMenuItem onClick={onMove}>
                <HugeiconsIcon icon={FolderExportIcon} />
                Move to directory
              </DropdownMenuItem>
            ) : (
              <DropdownMenuSub>
                <DropdownMenuSubTrigger>
                  <HugeiconsIcon icon={FolderExportIcon} />
                  Move to directory
                </DropdownMenuSubTrigger>
                <DropdownMenuSubContent className="w-56">
                  <MoveTargets dirs={dirs} current={dir} onPick={onMoveTo} />
                </DropdownMenuSubContent>
              </DropdownMenuSub>
            )}
            {dir !== ROOT && (
              <DropdownMenuItem onClick={() => void onMoveTo(ROOT)}>
                <HugeiconsIcon icon={FolderRemoveIcon} />
                Remove from directory
              </DropdownMenuItem>
            )}
          </DropdownMenuGroup>
        </DropdownMenuContent>
      </DropdownMenu>
    </SidebarMenuItem>
  )
}

/**
 * Where a session can go, in the row menu's submenu: a new directory, named in
 * the box, or one there is already. Making a directory is just moving
 * something into it — they are only prefixes, see `directories.ts`. A phone
 * picks from `MovePicker` instead.
 */
function MoveTargets({
  dirs,
  current,
  onPick,
}: {
  dirs: string[]
  current: string
  onPick: (dir: string) => Promise<void>
}) {
  const [typed, setTyped] = useState("")
  const [error, setError] = useState<string | null>(null)
  const others = dirs.filter((d) => d !== current)
  const pick = async (dir: string) => {
    if (dir === "" || dir === current) return
    try {
      await onPick(dir)
    } catch (e) {
      setError((e as Error).message)
    }
  }

  return (
    <>
      <label className="flex items-center gap-1.5 rounded-md px-1.5 py-1 text-sm focus-within:bg-accent">
        <HugeiconsIcon icon={FolderAddIcon} className="size-4 shrink-0 text-muted-foreground" />
        <input
          className="min-w-0 flex-1 bg-transparent outline-none placeholder:text-muted-foreground"
          placeholder="New directory"
          value={typed}
          onChange={(e) => {
            setTyped(e.target.value)
            setError(null)
          }}
          onKeyDown={(e) => {
            // The menu's own keys (typeahead, arrows) are not for a text box.
            e.stopPropagation()
            if (isComposing(e) || e.key !== "Enter") return
            e.preventDefault()
            void pick(dirName(typed))
          }}
        />
      </label>
      {error && <div className="px-1.5 py-1 text-xs text-destructive">{error}</div>}
      {others.length > 0 && <DropdownMenuSeparator />}
      {others.map((d) => (
        <DropdownMenuItem key={d} onClick={() => void pick(d)}>
          <HugeiconsIcon icon={Folder01Icon} />
          <span className="truncate">{d}</span>
        </DropdownMenuItem>
      ))}
    </>
  )
}

/**
 * Creating a session means choosing an engine, so "New chat" asks which.
 *
 * The choice cannot be changed later — the conversation lives in that engine's
 * own store — so it is made explicitly rather than defaulted. New sessions
 * start in Recents; "Move to directory" files them.
 */
function NewChat({ onCreate }: { onCreate: (backend: AgentBackend, profile?: string) => void }) {
  const [profiles, setProfiles] = useState<string[]>([])

  return (
    <SidebarMenuItem>
      <DropdownMenu
        // Read each time the menu opens: profiles are files on the server,
        // added by hand or by the agent, with nothing to announce them.
        onOpenChange={(open) => {
          if (open) listProfiles().then(setProfiles, () => setProfiles([]))
        }}
      >
        <DropdownMenuTrigger render={<SidebarMenuButton />}>
          <HugeiconsIcon icon={PlusSignIcon} />
          <span>New chat</span>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="start" className="w-(--anchor-width) min-w-52">
          <DropdownMenuItem onClick={() => onCreate("claude_code")}>Claude Code</DropdownMenuItem>
          {profiles.map((p) => (
            <DropdownMenuItem key={p} onClick={() => onCreate("claude_code", p)}>
              Claude Code · {p}
            </DropdownMenuItem>
          ))}
          <DropdownMenuItem onClick={() => onCreate("codex")}>Codex</DropdownMenuItem>
          <DropdownMenuItem onClick={() => onCreate("kiro")}>Kiro</DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </SidebarMenuItem>
  )
}

// The sidebar's widths, as multiples of its own: shut, itself, and a third
// wider. The handle lands on one of them, never between: a width a little off
// its own could never be dragged exactly back to it.
export const WIDE = 4 / 3
// Past this much of its own width, a sidebar dragged out opens and one dragged
// in stays open; short of it, shut.
const HALF = 0.5
// How far past a width a drag has to go to reach the next one up or down.
const NUDGE = 16

/**
 * The grip in the gap between the sidebar and the conversation, as Feishu has
 * it. The sidebar follows the drag, and on letting go settles on the nearest
 * of three widths in the drag's direction: shut, its own, a third wider. Out
 * half way opens it; a nudge past its own widens it; back the same way. A tap
 * opens or shuts it. Out in the gap rather
 * than on the sidebar's edge, so a drag that starts on text is still a
 * selection. Not on a phone, where the sidebar is a drawer.
 *
 * While dragging the width is set on the elements directly, not through
 * React: every frame through the app would re-render the conversation.
 */
export function SidebarHandle({ scale, onScale }: { scale: number; onScale: (scale: number) => void }) {
  const { open, setOpen, isMobile } = useSidebar()
  if (isMobile) return null

  const start = (e: React.PointerEvent<HTMLButtonElement>) => {
    if (e.button !== 0) return
    e.preventDefault()
    const handle = e.currentTarget
    const wrapper = handle.closest<HTMLElement>("[data-slot=sidebar-wrapper]")
    const bar = wrapper?.querySelector<HTMLElement>(":scope > [data-slot=sidebar]")
    if (!wrapper || !bar) return
    const rem = parseFloat(getComputedStyle(document.documentElement).fontSize)
    const base = 17 * rem
    const from = open ? base * scale : 0
    const x0 = e.clientX
    let width = from
    let moved = false
    handle.setPointerCapture(e.pointerId)
    const card = bar.querySelector<HTMLElement>("[data-slot=sidebar-container]")
    // The app's own width, which React set inline and puts back only when it
    // changes; so it is put back by hand.
    const own = wrapper.style.getPropertyValue("--sidebar-width")
    bar.style.transition = "none"
    if (card) card.style.transition = "none"

    const move = (ev: PointerEvent) => {
      if (!moved && Math.abs(ev.clientX - x0) < 4) return
      if (!moved) {
        moved = true
        bar.style.width = `${from}px`
        if (!open) setOpen(true)
      }
      width = Math.min(base * WIDE + NUDGE, Math.max(0, from + ev.clientX - x0))
      // The card keeps a width it can be read at and slides out of sight;
      // only the room it takes shrinks below that.
      wrapper.style.setProperty("--sidebar-width", `${Math.max(width, base * HALF)}px`)
      bar.style.width = `${width}px`
    }
    const end = () => {
      handle.removeEventListener("pointermove", move)
      handle.removeEventListener("pointerup", end)
      handle.removeEventListener("pointercancel", end)
      wrapper.style.setProperty("--sidebar-width", own)
      bar.style.width = ""
      bar.style.transition = ""
      if (card) card.style.transition = ""
      if (!moved) return setOpen(!open)
      const to =
        width > from
          ? width >= base + NUDGE
            ? WIDE
            : width >= base * HALF
              ? 1
              : 0
          : width <= base * HALF
            ? 0
            : width <= base * WIDE - NUDGE
              ? 1
              : WIDE
      if (to === 0) setOpen(false)
      else onScale(to)
    }
    handle.addEventListener("pointermove", move)
    handle.addEventListener("pointerup", end)
    handle.addEventListener("pointercancel", end)
  }

  return (
    <div className="relative w-0 shrink-0">
      <button
        type="button"
        aria-label={open ? "Drag to resize or shut the sidebar" : "Drag to open the sidebar"}
        title={open ? "Drag to resize; tap to shut" : "Drag or tap to open"}
        onPointerDown={start}
        // In the 8px gap: the sidebar's own margin when it is open, the
        // conversation's when it is shut.
        className={
          "group/handle absolute top-1/2 z-20 flex h-16 w-4 -translate-1/2 cursor-col-resize touch-none items-center justify-center pointer-coarse:h-20 pointer-coarse:w-7 " +
          (open ? "-left-1" : "left-1")
        }
      >
        <span className="h-10 w-1 rounded-full bg-muted-foreground/25 transition-colors group-hover/handle:bg-muted-foreground/60 group-active/handle:bg-muted-foreground/80" />
      </button>
    </div>
  )
}
