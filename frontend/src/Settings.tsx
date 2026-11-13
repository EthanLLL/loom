import {
  Cancel01Icon,
  ComputerPhoneSyncIcon,
  SecurityCheckIcon,
  Settings01Icon,
} from "@hugeicons/core-free-icons"
import { HugeiconsIcon, type IconSvgElement } from "@hugeicons/react"
import { useState, type ReactNode } from "react"
import { Button } from "@/components/ui/button"
import { Dialog, DialogClose, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import {
  Sidebar,
  SidebarContent,
  SidebarGroup,
  SidebarGroupContent,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
} from "@/components/ui/sidebar"
import { Switch } from "@/components/ui/switch"
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group"
import type { Device } from "./api"
import { DevicesPanel } from "./Devices"
import type { Push } from "./push"
import { SecurityPanel } from "./Security"
import { setThemePref, useThemePref, type ThemePref } from "./theme"
import { useNarrow } from "./useNarrow"
import { useViewportReadout } from "./ViewportReadout"

type Section = "general" | "devices" | "sign-in"

const SECTIONS: { id: Section; label: string; icon: IconSvgElement }[] = [
  { id: "general", label: "General", icon: Settings01Icon },
  { id: "devices", label: "Devices", icon: ComputerPhoneSyncIcon },
  { id: "sign-in", label: "Sign-in", icon: SecurityCheckIcon },
]

/**
 * Settings, with its sections down the left as shadcn's settings dialog has
 * them; a phone has no width for that, so they go across the top instead.
 *
 * General is this device's own: theme, Vim keys (desktop only) and
 * notifications. Devices and Sign-in are this Loom's: the machines its agents
 * reach, and how it is signed in to.
 */
export function SettingsDialog({
  open,
  onOpenChange,
  push,
  vim,
  devices,
  onUpsertDevice,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  push: Push
  vim: { on: boolean; toggle: () => void } | null
  devices: Device[]
  onUpsertDevice: (device: Device) => void
}) {
  const [section, setSection] = useState<Section>("general")
  const narrow = useNarrow()
  const online = devices.filter((d) => d.online).length

  const label = (id: Section) =>
    id === "devices" && devices.length > 0 ? `Devices · ${online}/${devices.length}` : SECTIONS.find((s) => s.id === id)!.label

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent
        showCloseButton={false}
        className="flex h-[min(34rem,calc(100dvh-2rem))] flex-col gap-0 overflow-hidden p-0 sm:max-w-[46rem] max-sm:h-dvh max-sm:max-w-none max-sm:rounded-none max-sm:pt-[env(safe-area-inset-top)] max-sm:pb-[env(safe-area-inset-bottom)] max-sm:ring-0">
        <DialogTitle className="sr-only">Settings</DialogTitle>
        <DialogDescription className="sr-only">This device's preferences, your devices, and sign-in.</DialogDescription>
        <SidebarProvider className="min-h-0 flex-1 items-stretch">
          {!narrow && (
            <Sidebar collapsible="none" className="w-48 border-r">
              <SidebarContent>
                <SidebarGroup>
                  <SidebarGroupContent>
                    <SidebarMenu>
                      {SECTIONS.map((s) => (
                        <SidebarMenuItem key={s.id}>
                          <SidebarMenuButton isActive={section === s.id} onClick={() => setSection(s.id)}>
                            <HugeiconsIcon icon={s.icon} />
                            <span>{label(s.id)}</span>
                          </SidebarMenuButton>
                        </SidebarMenuItem>
                      ))}
                    </SidebarMenu>
                  </SidebarGroupContent>
                </SidebarGroup>
              </SidebarContent>
            </Sidebar>
          )}
          <main className="flex min-w-0 flex-1 flex-col overflow-hidden">
            <header className="flex h-14 shrink-0 items-center gap-2 px-5 pr-3 max-sm:pl-3">
              {narrow ? (
                <ToggleGroup
                  value={[section]}
                  onValueChange={(v: string[]) => v[0] && setSection(v[0] as Section)}
                  variant="outline"
                >
                  {SECTIONS.map((s) => (
                    <ToggleGroupItem key={s.id} value={s.id} className="pointer-coarse:h-10">
                      {s.label}
                    </ToggleGroupItem>
                  ))}
                </ToggleGroup>
              ) : (
                <h2 className="text-base font-medium">{SECTIONS.find((s) => s.id === section)!.label}</h2>
              )}
              {/* In the bar rather than over the corner, so on a phone it is
                  under the status bar with the rest. */}
              <DialogClose render={<Button variant="ghost" size="icon-sm" className="ml-auto" />}>
                <HugeiconsIcon icon={Cancel01Icon} />
                <span className="sr-only">Close</span>
              </DialogClose>
            </header>
            <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-5 pb-5 max-sm:px-3">
              {section === "general" && <General push={push} vim={vim} />}
              {section === "devices" && <DevicesPanel devices={devices} onUpsert={onUpsertDevice} />}
              {section === "sign-in" && <SecurityPanel />}
            </div>
          </main>
        </SidebarProvider>
      </DialogContent>
    </Dialog>
  )
}

const THEMES: { value: ThemePref; label: string }[] = [
  { value: "system", label: "System" },
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
  { value: "coolnight", label: "Cool Night" },
]

const PUSH_HINT: Record<Push["state"], string> = {
  on: "This device is notified when a turn ends.",
  off: "Get a notification on this device when a turn ends.",
  denied: "Notifications are blocked for this site in the browser's settings.",
  unsupported: "On an iPhone, add Loom to the Home Screen and open it from there to get notifications.",
}

function General({ push, vim }: { push: Push; vim: { on: boolean; toggle: () => void } | null }) {
  const pref = useThemePref()
  const [readout, setReadout] = useViewportReadout()
  return (
    <div className="flex flex-col divide-y rounded-xl border">
      <Row title="Theme" hint={pref === "system" ? "Follows this device's light or dark setting." : undefined}>
        <ToggleGroup
          value={[pref]}
          onValueChange={(v: string[]) => v[0] && setThemePref(v[0] as ThemePref)}
          variant="outline"
          size="sm"
          className="flex-wrap"
        >
          {THEMES.map((t) => (
            <ToggleGroupItem key={t.value} value={t.value} className="pointer-coarse:h-9">
              {t.label}
            </ToggleGroupItem>
          ))}
        </ToggleGroup>
      </Row>
      {vim && (
        <Row title="Vim mode" hint="Keys for the panes; ? lists them.">
          <Switch checked={vim.on} onCheckedChange={vim.toggle} />
        </Row>
      )}
      <Row title="Notifications" hint={push.error ?? PUSH_HINT[push.state]}>
        <Switch
          checked={push.state === "on"}
          onCheckedChange={push.toggle}
          disabled={push.busy || push.state === "denied" || push.state === "unsupported"}
        />
      </Row>
      {/* For chasing the Home Screen app's viewport bugs on the device. */}
      <Row title="Viewport readout" hint="Shows what the browser reports about the window, for debugging.">
        <Switch checked={readout} onCheckedChange={setReadout} />
      </Row>
    </div>
  )
}

/** A setting: what it is and a word on it, its control on the right. */
export function Row({ title, hint, children }: { title: ReactNode; hint?: ReactNode; children?: ReactNode }) {
  return (
    // The control goes under the words when the two do not fit side by side.
    <div className="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3">
      <div className="flex min-w-40 flex-1 flex-col gap-0.5">
        <div className="text-sm font-medium">{title}</div>
        {hint && <div className="text-xs text-muted-foreground">{hint}</div>}
      </div>
      {children}
    </div>
  )
}
