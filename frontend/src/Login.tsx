import { FingerPrintIcon } from "@hugeicons/core-free-icons"
import { HugeiconsIcon } from "@hugeicons/react"
import { useEffect, useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Separator } from "@/components/ui/separator"
import { authOptions, login, passkeyLogin, passkeysSupported, type AuthOptions } from "./api"

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
    // A card in the middle, as shadcn's login blocks have it.
    <div className="flex h-full items-center justify-center bg-background p-4 font-sans">
      <form
        className="flex w-full max-w-xs flex-col gap-3 rounded-xl bg-card p-6 text-card-foreground ring-1 ring-foreground/10"
        onSubmit={submit}
      >
        <div className="mb-2 text-center">
          <h1 className="text-xl font-semibold">Loom</h1>
          <p className="text-sm text-muted-foreground">Sign in to continue</p>
        </div>
        {offerPasskey && (
          <>
            <Button type="button" size="lg" onClick={withPasskey} disabled={busy}>
              <HugeiconsIcon icon={FingerPrintIcon} />
              Sign in with passkey
            </Button>
            <div className="flex items-center gap-3 text-xs text-muted-foreground">
              <Separator className="flex-1" />
              or
              <Separator className="flex-1" />
            </div>
          </>
        )}
        {/* 16px everywhere: iOS zooms the page into any smaller field. */}
        <Input
          type="password"
          className={FIELD}
          placeholder="Password"
          value={password}
          autoFocus={!offerPasskey}
          autoComplete="current-password"
          onChange={(e) => setPassword(e.target.value)}
        />
        {options?.totp && (
          <Input
            className={FIELD}
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
        {error && <div className="text-center text-sm text-destructive">{error}</div>}
        {/* With a passkey on offer, the password is the way in on other
            devices, so it is the quieter button. */}
        <Button
          type="submit"
          size="lg"
          variant={offerPasskey ? "outline" : "default"}
          disabled={busy || !password || (options?.totp === true && !code.trim())}
        >
          {busy ? "…" : "Sign in"}
        </Button>
      </form>
    </div>
  )
}

const FIELD = "h-9 text-base! pointer-coarse:h-[44px]"
