export class UnauthorizedError extends Error {
  constructor() {
    super("unauthorized")
    this.name = "UnauthorizedError"
  }
}

// Token lives in sessionStorage → cleared when the browser closes, so every
// new browser session must re-enter the password.
const TOKEN_KEY = "loom_token"

export function getToken(): string | null {
  return sessionStorage.getItem(TOKEN_KEY)
}

export function setToken(token: string) {
  sessionStorage.setItem(TOKEN_KEY, token)
}

export function clearToken() {
  sessionStorage.removeItem(TOKEN_KEY)
}

export async function login(password: string): Promise<string> {
  const res = await fetch("/api/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ password }),
  })
  if (res.status === 401) throw new Error("invalid_password")
  if (!res.ok) throw new Error(`login failed: ${res.status}`)
  const data = await res.json()
  setToken(data.token)
  return data.token
}

function authHeaders(): Record<string, string> {
  const t = getToken()
  return t ? { Authorization: `Bearer ${t}` } : {}
}

export type SessionInfo = {
  id: string
  title: string | null
  created_at: number
  cols: number
  rows: number
}

export async function listSessions(): Promise<SessionInfo[]> {
  const res = await fetch("/api/sessions", { headers: authHeaders() })
  if (res.status === 401) throw new UnauthorizedError()
  if (!res.ok) throw new Error(`listSessions failed: ${res.status}`)
  const data = await res.json()
  return data.sessions
}

export async function createSession(title?: string): Promise<SessionInfo> {
  const res = await fetch("/api/sessions", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify(title ? { title } : {}),
  })
  if (res.status === 401) throw new UnauthorizedError()
  if (!res.ok) throw new Error(`createSession failed: ${res.status}`)
  return res.json()
}

export async function deleteSession(id: string): Promise<void> {
  const res = await fetch(`/api/sessions/${id}`, {
    method: "DELETE",
    headers: authHeaders(),
  })
  if (res.status === 401) throw new UnauthorizedError()
  if (!res.ok && res.status !== 404) {
    throw new Error(`deleteSession failed: ${res.status}`)
  }
}

export type Tab = {
  id: string
  panes: string[] // session ids, left → right
}

export type Layout = {
  tabs: Tab[]
  active_tab: string | null
}

export async function getLayout(): Promise<Layout> {
  const res = await fetch("/api/layout", { headers: authHeaders() })
  if (res.status === 401) throw new UnauthorizedError()
  if (!res.ok) throw new Error(`getLayout failed: ${res.status}`)
  return res.json()
}

export async function putLayout(layout: Layout): Promise<Layout> {
  const res = await fetch("/api/layout", {
    method: "PUT",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify(layout),
  })
  if (res.status === 401) throw new UnauthorizedError()
  if (!res.ok) throw new Error(`putLayout failed: ${res.status}`)
  return res.json()
}
