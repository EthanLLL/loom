import { ArrowLeft01Icon, Cancel01Icon, LinkSquare02Icon, Maximize01Icon, Minimize01Icon } from "@hugeicons/core-free-icons"
import { useState } from "react"
import type { AppInfo } from "./api"
import { PaneButton, PaneHead, PaneLink, PaneTitle } from "./Pane"

/**
 * The apps (`Loom.Apps`) as a home screen: a grid of icons in the user's
 * order that scrolls down when there are many, and one picked opens full size
 * in the pane. The pane is the right-hand column, beside the chat like the
 * canvas, and on a phone it covers the chat. The list is the lobby's, so an
 * app an agent just made appears without a reload. Each page is on the apps'
 * own origin (Caddy, see `Loom.Apps`), which is the isolation, so the frame
 * keeps it — the page gets its cookie and storage — and the page can be
 * opened in a tab of its own, which is where a browser offers to install it.
 */

const SANDBOX =
  "allow-scripts allow-forms allow-popups allow-modals allow-downloads allow-same-origin"
export function Apps({
  apps,
  narrow,
  maximized,
  onToggleMaximized,
  onClose,
}: {
  apps: AppInfo[]
  narrow: boolean
  maximized: boolean
  onToggleMaximized: () => void
  onClose: () => void
}) {
  const [open, setOpen] = useState<AppInfo | null>(null)

  return (
    <div className="flex size-full min-h-0 min-w-0 flex-1 flex-col bg-background">
      <PaneHead
        main
        title={
          <>
            {open && <PaneButton icon={ArrowLeft01Icon} onClick={() => setOpen(null)} title="Back to apps" />}
            <PaneTitle>{open ? open.title : "Apps"}</PaneTitle>
          </>
        }
      >
        {open && (
          <PaneLink icon={LinkSquare02Icon} href={open.url} target="_blank" rel="noopener" title="Open in its own tab" />
        )}
        {!narrow && (
          <PaneButton
            icon={maximized ? Minimize01Icon : Maximize01Icon}
            onClick={onToggleMaximized}
            title={maximized ? "Back beside the chat (Esc)" : "Full window"}
          />
        )}
        <PaneButton icon={Cancel01Icon} onClick={onClose} title="Close" />
      </PaneHead>
      {open ? (
        <iframe className="w-full flex-1 border-0" src={open.url} title={open.title} sandbox={SANDBOX} />
      ) : (
        // A home screen: fixed-size tiles, as many to a row as fit, and the
        // rest further down; on a phone four to a row, as on its own.
        <div className="grid min-h-0 flex-1 auto-rows-max grid-cols-[repeat(auto-fill,112px)] content-start gap-x-5 gap-y-7 overflow-y-auto px-12 py-10 font-sans max-sm:grid-cols-4 max-sm:gap-x-2 max-sm:gap-y-6 max-sm:px-3 max-sm:py-6">
          {apps.length === 0 && (
            <p className="col-span-full text-sm text-muted-foreground">No apps yet. Ask an agent to make one.</p>
          )}
          {apps.map((app) => (
            <button
              key={app.name}
              className="group/tile flex cursor-pointer flex-col items-center gap-2.5 text-foreground outline-none"
              onClick={() => setOpen(app)}
              title={app.name}
            >
              {app.icon ? (
                <img className={ICON + " object-cover"} src={app.icon} alt="" />
              ) : (
                <span className={ICON + " flex items-center justify-center bg-muted text-3xl max-sm:text-2xl"}>
                  {app.title.slice(0, 1).toUpperCase()}
                </span>
              )}
              <span className="max-w-full truncate text-center text-sm max-sm:text-xs">{app.title}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

const ICON =
  "size-18 rounded-[18px] shadow-md ring-1 ring-foreground/10 transition-transform duration-100 group-hover/tile:scale-106 group-focus-visible/tile:scale-106 group-active/tile:scale-96 max-sm:size-15 max-sm:rounded-[15px]"
