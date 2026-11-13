import { X } from "lucide-react"
import qrcode from "qrcode-generator"
import { useCallback, useEffect, useState } from "react"
import { createPortal } from "react-dom"
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
 * How this Loom is signed in to, from Settings: passkeys, the authenticator
 * app, and the devices signed in now. See `Loom.Auth`.
 */
export function SecurityDialog({ onClose }: { onClose: () => void }) {
  const [overview, setOverview] = useState<AuthOverview | null>(null)
  const [error, setError] = useState<string | null>(null)

  const reload = useCallback(() => {
    authOverview()
      .then(setOverview)
      .catch((e) => setError((e as Error).message))
  }, [])

  useEffect(reload, [reload])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose()
    document.addEventListener("keydown", onKey)
    return () => document.removeEventListener("keydown", onKey)
  }, [onClose])

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

  return createPortal(
    <div className="modal-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal devices security" role="dialog" aria-label="Sign-in">
        <div className="modal-head">
          <span>Sign-in</span>
          <button className="icon-btn" onClick={onClose} title="Close">
            <X />
          </button>
        </div>

        <div className="device-list">
          {overview && (
            <>
              <Passkeys overview={overview} run={run} />
              <Authenticator overview={overview} run={run} />
              <Logins overview={overview} run={run} />
            </>
          )}
        </div>

        {error && <div className="device-error">{error}</div>}
      </div>
    </div>,
    document.body,
  )
}

type Section = { overview: AuthOverview; run: (action: () => Promise<unknown>) => Promise<void> }

function Passkeys({ overview, run }: Section) {
  return (
    <section className="security-section">
      <div className="security-head">
        <span>Passkeys</span>
        <button
          className="device-action"
          onClick={() => run(registerPasskey)}
          disabled={!passkeysSupported()}
          title="Face ID, Touch ID or Windows Hello on this device, or a phone nearby"
        >
          add
        </button>
      </div>
      {overview.passkeys.length === 0 && (
        <div className="device-empty">
          None yet. Add one to sign in with Face ID, Touch ID or Windows Hello; on Apple devices it
          syncs through iCloud Keychain, so one is enough for all of them.
        </div>
      )}
      {overview.passkeys.map((p) => (
        <div className="device" key={p.id}>
          <div className="device-body">
            <span className="device-name">{p.name}</span>
            <span className="device-meta">
              {[`added ${day(p.created_at)}`, p.last_used_at ? `used ${since(p.last_used_at)}` : "never used"].join(" · ")}
            </span>
          </div>
          <button
            className="session-del device-del"
            title="Remove passkey"
            onClick={() =>
              confirm(`Remove the passkey made on ${p.name}? It stops working here; delete it from the device's passwords too.`) &&
              run(() => deletePasskey(p.id))
            }
          >
            <X />
          </button>
        </div>
      ))}
    </section>
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
    <section className="security-section">
      <div className="security-head">
        <span>Authenticator app</span>
        {totp ? (
          <button
            className="device-action"
            onClick={() =>
              confirm("Remove the authenticator? The password alone will sign in again.") && run(totpRemove)
            }
          >
            remove
          </button>
        ) : (
          !secret && (
            <button className="device-action" onClick={() => run(async () => setSecret(await totpBegin()))}>
              set up
            </button>
          )
        )}
      </div>
      <div className="device-empty">
        {totp
          ? `On: the password needs a code from the app. ${totp.recovery_left} recovery codes left.`
          : "Off: the password alone signs in. Set one up and the password needs a 6-digit code too."}
      </div>
      {secret && !totp && (
        <form
          className="install-box totp-setup"
          onSubmit={(e) => {
            e.preventDefault()
            void run(async () => {
              setRecovery(await totpConfirm(code))
              setSecret(null)
              setCode("")
            })
          }}
        >
          <div className="install-hint">
            Scan with an authenticator app (iPhone Passwords, Google Authenticator, 1Password…), or on
            this phone <a href={otpauth(secret)}>open it in the app</a>. Then enter the code it shows.
          </div>
          <img className="totp-qr" src={qr(otpauth(secret))} alt="QR code for the authenticator" />
          <code className="install-command">{secret.replace(/(.{4})/g, "$1 ").trim()}</code>
          <div className="install-actions">
            <input
              className="device-name-input"
              value={code}
              onChange={(e) => setCode(e.target.value)}
              placeholder="6-digit code"
              inputMode="numeric"
              autoComplete="one-time-code"
            />
            <button type="submit" className="text-btn" disabled={code.trim().length < 6}>
              Confirm
            </button>
            <button type="button" className="text-btn" onClick={() => setSecret(null)}>
              Cancel
            </button>
          </div>
        </form>
      )}
    </section>
  )
}

function RecoveryCodes({ codes, onDone }: { codes: string[]; onDone: () => void }) {
  const [copied, setCopied] = useState(false)
  const text = codes.join("\n")
  return (
    <section className="security-section">
      <div className="security-head">
        <span>Authenticator app</span>
      </div>
      <div className="install-box">
        <div className="install-hint">
          Set up. Keep these recovery codes somewhere safe: each one stands in for a code once, if
          the phone is lost. They are not shown again.
        </div>
        <code className="install-command recovery-codes">{text}</code>
        <div className="install-actions">
          <button
            className="text-btn"
            onClick={() =>
              navigator.clipboard
                .writeText(text)
                .then(() => setCopied(true))
                .catch(() => {})
            }
          >
            {copied ? "Copied" : "Copy"}
          </button>
          <button className="text-btn" onClick={onDone}>
            Saved them
          </button>
        </div>
      </div>
    </section>
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
    <section className="security-section">
      <div className="security-head">
        <span>Signed in</span>
      </div>
      {overview.logins.map((l) => (
        <div className="device" key={l.id}>
          <div className="device-body">
            <span className="device-name">
              {l.name}
              {l.id === overview.current && <span className="security-this">this device</span>}
            </span>
            <span className="device-meta">
              {[l.method, l.ip, `active ${since(l.last_seen_at)}`, `since ${day(l.created_at)}`]
                .filter(Boolean)
                .join(" · ")}
            </span>
          </div>
          <button className="session-del device-del" title="Sign out" onClick={() => revoke(l)}>
            <X />
          </button>
        </div>
      ))}
      <div className="device-empty">A device unused for {overview.idle_days} days is signed out.</div>
    </section>
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
