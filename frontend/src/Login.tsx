import { useState } from "react"
import { login } from "./api"
import "./Login.css"

type Props = {
  onSuccess: () => void
}

export function Login({ onSuccess }: Props) {
  const [password, setPassword] = useState("")
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await login(password)
      onSuccess()
    } catch (err) {
      setError(
        err instanceof Error && err.message === "invalid_password"
          ? "Wrong password"
          : "Login failed",
      )
      setPassword("")
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="login">
      <form className="login-box" onSubmit={submit}>
        <div className="login-title">loom</div>
        <input
          type="password"
          className="login-input"
          placeholder="password"
          value={password}
          autoFocus
          onChange={(e) => setPassword(e.target.value)}
        />
        {error && <div className="login-error">{error}</div>}
        <button className="login-btn" type="submit" disabled={busy || !password}>
          {busy ? "…" : "Enter"}
        </button>
      </form>
    </div>
  )
}
