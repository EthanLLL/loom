import { Bell, BellOff, Keyboard, KeyboardOff, SunMoon, X } from "lucide-react"
import { useEffect } from "react"
import { createPortal } from "react-dom"
import type { Push } from "./push"
import { setThemePref, useThemePref, type ThemePref } from "./theme"

/**
 * Per-device preferences, kept out of the sidebar so its foot stays three
 * rows: theme, Vim keys (desktop only) and notifications.
 */
export function SettingsDialog({
  push,
  vim,
  onClose,
}: {
  push: Push
  vim: { on: boolean; toggle: () => void } | null
  onClose: () => void
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose()
    document.addEventListener("keydown", onKey)
    return () => document.removeEventListener("keydown", onKey)
  }, [onClose])

  return createPortal(
    <div className="modal-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal settings" role="dialog" aria-label="Settings">
        <div className="modal-head">
          <span>Settings</span>
          <button className="icon-btn" onClick={onClose} title="Close">
            <X />
          </button>
        </div>
        <div className="settings-list">
          <ThemeRow />
          {vim && (
            <button
              className={"devices-btn push-btn" + (vim.on ? " on" : "")}
              onClick={vim.toggle}
              title={vim.on ? "Vim mode is on; ? lists the keys. Click to turn it off." : "Turn on Vim mode: keys for the panes, ? lists them"}
            >
              {vim.on ? <Keyboard /> : <KeyboardOff />}
              <span>Vim mode</span>
              <span className="devices-count">{vim.on ? "on" : "off"}</span>
            </button>
          )}
          <PushRow push={push} />
        </div>
      </div>
    </div>,
    document.body,
  )
}

const THEMES: { value: ThemePref; label: string }[] = [
  { value: "system", label: "System" },
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
]

function ThemeRow() {
  const pref = useThemePref()
  return (
    <div className="devices-btn push-btn settings-theme">
      <SunMoon />
      <span>Theme</span>
      <span className="seg" role="radiogroup" aria-label="Theme">
        {THEMES.map((t) => (
          <button
            key={t.value}
            role="radio"
            aria-checked={pref === t.value}
            className={pref === t.value ? "on" : ""}
            onClick={() => setThemePref(t.value)}
            title={t.value === "system" ? "Follow this device's light or dark setting" : undefined}
          >
            {t.label}
          </button>
        ))}
      </span>
    </div>
  )
}

const PUSH_HINT: Record<Push["state"], string> = {
  on: "This device is notified when a turn ends. Click to stop.",
  off: "Get a notification on this device when a turn ends",
  denied: "Notifications are blocked for this site in the browser's settings",
  unsupported: "On an iPhone, add Loom to the Home Screen and open it from there to get notifications",
}

/** Notifications for this device, on or off; see `usePush`. */
function PushRow({ push }: { push: Push }) {
  const on = push.state === "on"
  const Icon = on ? Bell : BellOff
  return (
    <button
      className={"devices-btn push-btn" + (on ? " on" : "")}
      onClick={push.toggle}
      disabled={push.busy || push.state === "denied" || push.state === "unsupported"}
      title={push.error ?? PUSH_HINT[push.state]}
    >
      <Icon />
      <span>Notifications</span>
      <span className="devices-count">
        {push.error ? "failed" : push.busy ? "…" : on ? "on" : push.state === "off" ? "off" : "n/a"}
      </span>
    </button>
  )
}
