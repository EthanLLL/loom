import { Fingerprint } from "lucide-react"
import { useEffect, useState } from "react"
import { authOptions, login, passkeyLogin, passkeysSupported, type AuthOptions } from "./api"
import "./Login.css"

type Props = {
  onSuccess: () => void
}

/**
 * The two ways in (see `Loom.Auth`): a passkey, offered once one is
 * registered, or the password — with a code from the authenticator once one
 * is set up, where a recovery code also works.
 */
export function Login({ onSuccess }: Props) {
  const [options, setOptions] = useState<AuthOptions | null>(null)
  const [password, setPassword] = useState("")
  const [code, setCode] = useState("")
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    authOptions()
      .then(setOptions)
      .catch(() => setOptions({ passkey: false, totp: false }))
  }, [])

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await login(password, options?.totp ? code : undefined)
      onSuccess()
    } catch (err) {
      const message = err instanceof Error ? err.message : ""
      setError(
        message === "invalid_password"
          ? options?.totp
            ? "Wrong password or code"
            : "Wrong password"
          : message === "locked"
            ? "Too many tries; wait 15 minutes, or use a passkey"
            : "Login failed",
      )
      setPassword("")
      setCode("")
    } finally {
      setBusy(false)
    }
  }

  const withPasskey = async () => {
    setBusy(true)
    setError(null)
    try {
      await passkeyLogin()
      onSuccess()
    } catch (err) {
      // Dismissing the sheet is not an error worth a message.
      if (!(err instanceof DOMException && err.name === "NotAllowedError")) {
        setError("That passkey was not accepted")
      }
    } finally {
      setBusy(false)
    }
  }

  const offerPasskey = options?.passkey && passkeysSupported()

  return (
    <div className="login">
      <form className="login-box" onSubmit={submit}>
        <div className="login-title">loom</div>
        {offerPasskey && (
          <>
            <button type="button" className="login-btn login-passkey" onClick={withPasskey} disabled={busy}>
              <Fingerprint />
              Sign in with passkey
            </button>
            <div className="login-or">or</div>
          </>
        )}
        <input
          type="password"
          className="login-input"
          placeholder="password"
          value={password}
          autoFocus={!offerPasskey}
          autoComplete="current-password"
          onChange={(e) => setPassword(e.target.value)}
        />
        {options?.totp && (
          <input
            className="login-input"
            placeholder="6-digit code"
            value={code}
            inputMode="numeric"
            autoComplete="one-time-code"
            autoCapitalize="off"
            autoCorrect="off"
            spellCheck={false}
            title="From your authenticator app, or a recovery code"
            onChange={(e) => setCode(e.target.value)}
          />
        )}
        {error && <div className="login-error">{error}</div>}
        <button
          className={offerPasskey ? "login-btn login-secondary" : "login-btn"}
          type="submit"
          disabled={busy || !password || (options?.totp === true && !code.trim())}
        >
          {busy ? "…" : "Enter"}
        </button>
      </form>
    </div>
  )
}
