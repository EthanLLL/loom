import { Cancel01Icon } from "@hugeicons/core-free-icons"
import { HugeiconsIcon } from "@hugeicons/react"
import qrcode from "qrcode-generator"
import { useCallback, useEffect, useState, type ReactNode } from "react"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import {
  authOverview,
  deletePasskey,
  passkeysSupported,
  registerPasskey,
  revokeLogin,
  totpBegin,
  totpConfirm,
  totpRemove,
  type AuthOverview,
  type Login,
} from "./api"
import { ago } from "./format"

/**
 * How this Loom is signed in to, a section of Settings: passkeys, the
 * authenticator app, and the devices signed in now. See `Loom.Auth`.
 */
export function SecurityPanel() {
  const [overview, setOverview] = useState<AuthOverview | null>(null)
  const [error, setError] = useState<string | null>(null)

  const reload = useCallback(() => {
    authOverview()
      .then(setOverview)
      .catch((e) => setError((e as Error).message))
  }, [])

  useEffect(reload, [reload])

  const run = async (action: () => Promise<unknown>) => {
    setError(null)
    try {
      await action()
    } catch (e) {
      // Dismissing the system sheet is not an error worth a message.
      if (!(e instanceof DOMException && e.name === "NotAllowedError")) setError((e as Error).message)
    }
    reload()
  }

  return (
    <>
      {error && <p className="text-sm text-destructive">{error}</p>}
      {overview && (
        <>
          <Passkeys overview={overview} run={run} />
          <Authenticator overview={overview} run={run} />
          <Logins overview={overview} run={run} />
        </>
      )}
    </>
  )
}

type Section = { overview: AuthOverview; run: (action: () => Promise<unknown>) => Promise<void> }

/** A part of the panel: its name and action over a bordered list. */
function Part({ title, action, children }: { title: string; action?: ReactNode; children: ReactNode }) {
  return (
    <section className="flex flex-col gap-2">
      <div className="flex min-h-8 items-center justify-between gap-2">
        <h3 className="text-sm font-medium">{title}</h3>
        {action}
      </div>
      {children}
    </section>
  )
}

function Entry({ name, meta, onRemove, removeTitle }: { name: ReactNode; meta: string; onRemove: () => void; removeTitle: string }) {
  return (
    <div className="flex items-center gap-3 px-4 py-2.5">
      <div className="flex min-w-0 flex-1 flex-col">
        <span className="flex items-center gap-2 truncate text-sm font-medium">{name}</span>
        <span className="truncate text-xs text-muted-foreground">{meta}</span>
      </div>
      <Button variant="ghost" size="icon-sm" className="text-muted-foreground hover:text-destructive" title={removeTitle} onClick={onRemove}>
        <HugeiconsIcon icon={Cancel01Icon} />
      </Button>
    </div>
  )
}

const note = "text-sm text-muted-foreground"
const list = "flex flex-col divide-y rounded-xl border"

function Passkeys({ overview, run }: Section) {
  return (
    <Part
      title="Passkeys"
      action={
        <Button
          variant="outline"
          size="sm"
          onClick={() => run(registerPasskey)}
          disabled={!passkeysSupported()}
          title="Face ID, Touch ID or Windows Hello on this device, or a phone nearby"
        >
          Add passkey
        </Button>
      }
    >
      {overview.passkeys.length === 0 ? (
        <p className={note}>
          None yet. Add one to sign in with Face ID, Touch ID or Windows Hello; on Apple devices it
          syncs through iCloud Keychain, so one is enough for all of them.
        </p>
      ) : (
        <div className={list}>
          {overview.passkeys.map((p) => (
            <Entry
              key={p.id}
              name={p.name}
              meta={[`added ${day(p.created_at)}`, p.last_used_at ? `used ${since(p.last_used_at)}` : "never used"].join(" · ")}
              removeTitle="Remove passkey"
              onRemove={() =>
                confirm(`Remove the passkey made on ${p.name}? It stops working here; delete it from the device's passwords too.`) &&
                run(() => deletePasskey(p.id))
              }
            />
          ))}
        </div>
      )}
    </Part>
  )
}

function Authenticator({ overview, run }: Section) {
  // The secret being set up, then the recovery codes it produced.
  const [secret, setSecret] = useState<string | null>(null)
  const [code, setCode] = useState("")
  const [recovery, setRecovery] = useState<string[] | null>(null)

  if (recovery) return <RecoveryCodes codes={recovery} onDone={() => setRecovery(null)} />

  const totp = overview.totp
  return (
    <Part
      title="Authenticator app"
      action={
        totp ? (
          <Button
            variant="outline"
            size="sm"
            onClick={() =>
              confirm("Remove the authenticator? The password alone will sign in again.") && run(totpRemove)
            }
          >
            Remove
          </Button>
        ) : (
          !secret && (
            <Button variant="outline" size="sm" onClick={() => run(async () => setSecret(await totpBegin()))}>
              Set up
            </Button>
          )
        )
      }
    >
      <p className={note}>
        {totp
          ? `On: the password needs a code from the app. ${totp.recovery_left} recovery codes left.`
          : "Off: the password alone signs in. Set one up and the password needs a 6-digit code too."}
      </p>
      {secret && !totp && (
        <form
          className="flex flex-col gap-3 rounded-xl bg-muted p-4"
          onSubmit={(e) => {
            e.preventDefault()
            void run(async () => {
              setRecovery(await totpConfirm(code))
              setSecret(null)
              setCode("")
            })
          }}
        >
          <p className="text-xs text-muted-foreground">
            Scan with an authenticator app (iPhone Passwords, Google Authenticator, 1Password…), or on
            this phone{" "}
            <a className="underline" href={otpauth(secret)}>
              open it in the app
            </a>
            . Then enter the code it shows.
          </p>
          <img className="size-40 self-center rounded-md bg-white p-1" src={qr(otpauth(secret))} alt="QR code for the authenticator" />
          <code className="self-center font-mono text-xs select-all">{secret.replace(/(.{4})/g, "$1 ").trim()}</code>
          <div className="flex gap-2">
            <Input
              className="max-sm:text-base"
              value={code}
              onChange={(e) => setCode(e.target.value)}
              placeholder="6-digit code"
              inputMode="numeric"
              autoComplete="one-time-code"
            />
            <Button type="submit" disabled={code.trim().length < 6}>
              Confirm
            </Button>
            <Button type="button" variant="ghost" onClick={() => setSecret(null)}>
              Cancel
            </Button>
          </div>
        </form>
      )}
    </Part>
  )
}

function RecoveryCodes({ codes, onDone }: { codes: string[]; onDone: () => void }) {
  const [copied, setCopied] = useState(false)
  const text = codes.join("\n")
  return (
    <Part title="Authenticator app">
      <div className="flex flex-col gap-3 rounded-xl bg-muted p-4">
        <p className="text-xs text-muted-foreground">
          Set up. Keep these recovery codes somewhere safe: each one stands in for a code once, if
          the phone is lost. They are not shown again.
        </p>
        <code className="font-mono text-sm whitespace-pre select-all">{text}</code>
        <div className="flex justify-end gap-2">
          <Button
            variant="outline"
            size="sm"
            onClick={() =>
              navigator.clipboard
                .writeText(text)
                .then(() => setCopied(true))
                .catch(() => {})
            }
          >
            {copied ? "Copied" : "Copy"}
          </Button>
          <Button size="sm" onClick={onDone}>
            Saved them
          </Button>
        </div>
      </div>
    </Part>
  )
}

function Logins({ overview, run }: Section) {
  const revoke = (l: Login) => {
    const self = l.id === overview.current
    const message = self
      ? "Sign this device out?"
      : `Sign out ${l.name}? It has to sign in again to use Loom.`
    if (confirm(message)) void run(() => revokeLogin(l.id))
  }

  return (
    <Part title="Signed in">
      <div className={list}>
        {overview.logins.map((l) => (
          <Entry
            key={l.id}
            name={
              <>
                <span className="truncate">{l.name}</span>
                {l.id === overview.current && <Badge variant="secondary">this device</Badge>}
              </>
            }
            meta={[l.method, l.ip, `active ${since(l.last_seen_at)}`, `since ${day(l.created_at)}`]
              .filter(Boolean)
              .join(" · ")}
            removeTitle="Sign out"
            onRemove={() => revoke(l)}
          />
        ))}
      </div>
      <p className="text-xs text-muted-foreground">A device unused for {overview.idle_days} days is signed out.</p>
    </Part>
  )
}

function otpauth(secret: string): string {
  const label = encodeURIComponent(`Loom:${location.hostname}`)
  return `otpauth://totp/${label}?secret=${secret}&issuer=Loom&algorithm=SHA1&digits=6&period=30`
}

function qr(text: string): string {
  const code = qrcode(0, "M")
  code.addData(text)
  code.make()
  return code.createDataURL(4, 2)
}

function since(iso: string): string {
  const a = ago(Date.parse(iso))
  return a === "now" ? "just now" : `${a} ago`
}

function day(iso: string): string {
  return new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric" })
}
