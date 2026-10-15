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

// Reported verbatim by whichever backend ran the turn, and the two disagree
// about almost every key. Nothing here depends on the shape, so it stays
// opaque rather than being flattened into a lowest common denominator.
export type AgentUsage = Record<string, unknown>

export type AgentBackend = "claude_code" | "codex"

/**
 * `starting` is the gap between asking the backend to begin and it saying
 * anything — a cold Claude Code process takes seconds to boot.
 * Without a state for it the UI looks hung.
 *
 * `interrupted` is not a transition but a resting state: the turn was stopped
 * and the queue is parked until the user types.
 */
export type AgentStatus = "idle" | "starting" | "running" | "interrupted"

export type AgentInfo = {
  id: string
  title: string | null
  backend: AgentBackend
  backend_label: string
  created_at: number
  status: AgentStatus
  queued: number
  // The parked messages themselves, so an interrupted session can show what is
  // waiting and let the user drop a line that no longer applies.
  queue: string[]
  usage: AgentUsage | null
  // How big the conversation is now, from the backend's own last API call —
  // never the turn's cumulative token traffic, which is several times larger.
  context_tokens: number
  context_window: number | null
  turns: number
  // Orders summaries from the lobby channel: the higher one is newer.
  seq: number
}

export async function listAgents(): Promise<AgentInfo[]> {
  const res = await fetch("/api/agents", { headers: authHeaders() })
  if (res.status === 401) throw new UnauthorizedError()
  if (!res.ok) throw new Error(`listAgents failed: ${res.status}`)
  const data = await res.json()
  return data.sessions
}

// `backend` is required and permanent: the conversation lives in that engine's
// own store, so there is nothing to migrate if it changes later.
export async function createAgent(backend: AgentBackend): Promise<AgentInfo> {
  const res = await fetch("/api/agents", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ backend }),
  })
  if (res.status === 401) throw new UnauthorizedError()
  if (!res.ok) throw new Error(`createAgent failed: ${res.status}`)
  return res.json()
}

// Local to loom — a sidebar label, never pushed to the backend.
export async function renameAgent(
  id: string,
  title: string,
): Promise<AgentInfo> {
  const res = await fetch(`/api/agents/${id}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ title }),
  })
  if (res.status === 401) throw new UnauthorizedError()
  if (!res.ok) throw new Error(`renameAgent failed: ${res.status}`)
  return res.json()
}

// Permanent: the server discards the session's history too, otherwise it would
// reappear at the next boot when Bootstrap restores everything on disk.
export async function deleteAgent(id: string): Promise<void> {
  const res = await fetch(`/api/agents/${id}`, {
    method: "DELETE",
    headers: authHeaders(),
  })
  if (res.status === 401) throw new UnauthorizedError()
  if (!res.ok && res.status !== 404) {
    throw new Error(`deleteAgent failed: ${res.status}`)
  }
}

/**
 * A file stored under the session's own directory, as the server named it.
 *
 * `path` is absolute and goes to the model in the message it receives; the
 * backend reads it with its own tools. The server re-checks it belongs to this
 * session on submit, so a rewritten path is refused rather than read.
 */
export type AgentFile = {
  name: string
  path: string
  size: number
  content_type: string
}

/**
 * Upload attachments for a session.
 *
 * Over HTTP rather than the channel: a 20 MB screenshot sent as a WebSocket
 * frame would sit in front of every event and delta on the same socket.
 */
export async function uploadAgentFiles(
  id: string,
  files: File[],
): Promise<AgentFile[]> {
  const body = new FormData()
  for (const file of files) body.append("files[]", file)

  // No Content-Type header: the browser has to set the multipart boundary.
  const res = await fetch(`/api/agents/${id}/files`, {
    method: "POST",
    headers: authHeaders(),
    body,
  })
  if (res.status === 401) throw new UnauthorizedError()
  if (!res.ok) {
    const detail = await res.json().catch(() => null)
    throw new Error(detail?.error ?? `upload failed: ${res.status}`)
  }
  return (await res.json()).files
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
