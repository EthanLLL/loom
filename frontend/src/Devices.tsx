import { Cancel01Icon } from "@hugeicons/core-free-icons"
import { HugeiconsIcon } from "@hugeicons/react"
import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { isComposing } from "./ime"
import {
  createDevice,
  deleteDevice,
  deviceInstallCode,
  installCommand,
  renameDevice,
  type Device,
} from "./api"

/**
 * The user's machines that agents can reach through `loom-node` — add, rename,
 * remove, and get the command that installs one. A section of Settings.
 *
 * Who is online comes from the lobby channel, so the dots change while it is
 * open. The install command is shown once, right after it is made: the code in
 * it works one time, for an hour, and the token it hands the device exists
 * nowhere else.
 */
export function DevicesPanel({
  devices,
  onUpsert,
}: {
  devices: Device[]
  onUpsert: (device: Device) => void
}) {
  const [name, setName] = useState("")
  const [error, setError] = useState<string | null>(null)
  // The device whose install command is on screen, and the command.
  const [install, setInstall] = useState<{ id: string; command: string } | null>(null)

  const add = async () => {
    const value = name.trim()
    if (value === "") return
    try {
      const { node, code } = await createDevice(value)
      onUpsert(node)
      setName("")
      setError(null)
      setInstall({ id: node.id, command: installCommand(code) })
    } catch (e) {
      setError((e as Error).message)
    }
  }

  const reinstall = async (device: Device) => {
    try {
      const { code } = await deviceInstallCode(device.id)
      setError(null)
      setInstall({ id: device.id, command: installCommand(code) })
    } catch (e) {
      setError((e as Error).message)
    }
  }

  const remove = async (device: Device) => {
    if (!confirm(`Remove ${device.name}? Its loom-node stops working until it is added and installed again.`)) return
    try {
      await deleteDevice(device.id)
      if (install?.id === device.id) setInstall(null)
      setError(null)
    } catch (e) {
      setError((e as Error).message)
    }
  }

  const rename = async (device: Device, value: string) => {
    try {
      const { node } = await renameDevice(device.id, value)
      onUpsert(node)
      setError(null)
    } catch (e) {
      setError((e as Error).message)
    }
  }

  return (
    <>
      {devices.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No devices yet. Add your Mac or a WSL box, run the command it gives you there, and agents
          can run commands on it.
        </p>
      ) : (
        <div className="flex flex-col divide-y rounded-xl border">
          {devices.map((d) => (
            <div key={d.id}>
              <DeviceRow
                device={d}
                onRename={(value) => rename(d, value)}
                onReinstall={() => reinstall(d)}
                onRemove={() => remove(d)}
              />
              {install?.id === d.id && (
                <InstallBox command={install.command} onDone={() => setInstall(null)} />
              )}
            </div>
          ))}
        </div>
      )}

      {error && <p className="text-sm text-destructive">{error}</p>}

      <form
        className="flex gap-2"
        onSubmit={(e) => {
          e.preventDefault()
          void add()
        }}
      >
        <Input
          className="max-sm:text-base pointer-coarse:h-10"
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="name, e.g. mac"
          autoCapitalize="off"
          autoCorrect="off"
          spellCheck={false}
        />
        <Button type="submit" disabled={name.trim() === ""}>
          Add device
        </Button>
      </form>
    </>
  )
}

function DeviceRow({
  device,
  onRename,
  onReinstall,
  onRemove,
}: {
  device: Device
  onRename: (name: string) => void
  onReinstall: () => void
  onRemove: () => void
}) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(device.name)

  const commit = () => {
    const value = draft.trim()
    if (value !== "" && value !== device.name) onRename(value)
    setEditing(false)
  }

  const system = device.os ? `${device.os}/${device.arch}` : null

  return (
    <div className="flex items-center gap-3 px-4 py-2.5">
      {/* Lit while connected. Steady, not pulsing: pulsing means working. */}
      <span
        className={"size-2 shrink-0 rounded-full " + (device.online ? "bg-emerald-500" : "bg-muted-foreground/40")}
        title={device.online ? "online" : "offline"}
      />
      <div className="flex min-w-0 flex-1 flex-col">
        {editing ? (
          <Input
            className="h-7 max-sm:text-base"
            value={draft}
            autoFocus
            onChange={(e) => setDraft(e.target.value)}
            onBlur={commit}
            onKeyDown={(e) => {
              if (isComposing(e)) return
              if (e.key === "Enter") commit()
              if (e.key === "Escape") {
                setDraft(device.name)
                setEditing(false)
              }
            }}
          />
        ) : (
          <span
            className="truncate text-sm font-medium"
            title="Double-click to rename"
            onDoubleClick={() => {
              setDraft(device.name)
              setEditing(true)
            }}
          >
            {device.name}
          </span>
        )}
        <span className="truncate text-xs text-muted-foreground">
          {[system, device.hostname, seen(device)].filter(Boolean).join(" · ")}
        </span>
      </div>
      <Button
        variant="outline"
        size="sm"
        onClick={onReinstall}
        title="New install command (replaces this device's token)"
      >
        Install
      </Button>
      <Button variant="ghost" size="icon-sm" className="text-muted-foreground hover:text-destructive" onClick={onRemove} title="Remove device">
        <HugeiconsIcon icon={Cancel01Icon} />
      </Button>
    </div>
  )
}

function InstallBox({ command, onDone }: { command: string; onDone: () => void }) {
  const [copied, setCopied] = useState(false)

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(command)
      setCopied(true)
    } catch {
      // No clipboard (an http origin): the text is selectable instead.
    }
  }

  return (
    <div className="mx-4 mb-3 flex flex-col gap-2 rounded-lg bg-muted p-3">
      <div className="text-xs text-muted-foreground">Run this in a terminal on the device — it works once, within an hour:</div>
      <code className="font-mono text-xs break-all select-all" onClick={(e) => selectAll(e.currentTarget)}>
        {command}
      </code>
      <div className="flex justify-end gap-2">
        <Button variant="outline" size="sm" onClick={copy}>
          {copied ? "Copied" : "Copy"}
        </Button>
        <Button size="sm" onClick={onDone}>
          Done
        </Button>
      </div>
    </div>
  )
}

function selectAll(el: HTMLElement) {
  const range = document.createRange()
  range.selectNodeContents(el)
  const selection = window.getSelection()
  selection?.removeAllRanges()
  selection?.addRange(range)
}

function seen(device: Device): string {
  if (device.online) return "online"
  if (!device.last_seen_at) return "never connected"
  const mins = Math.floor((Date.now() - Date.parse(device.last_seen_at)) / 60000)
  if (mins < 1) return "seen just now"
  if (mins < 60) return `seen ${mins}m ago`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `seen ${hours}h ago`
  return `seen ${Math.floor(hours / 24)}d ago`
}
