export class UnauthorizedError extends Error {
  constructor() {
    super("unauthorized")
    this.name = "UnauthorizedError"
  }
}

// Token lives in localStorage, so it survives the app being closed. On iOS the
// only way to reload a home-screen web app is to kill it, and sessionStorage
// made every reload a password prompt. The server's 30-day max_age is what
// eventually logs a device out.
const TOKEN_KEY = "loom_token"

// Who to tell when the server stops accepting the token. Set once by `App`.
let unauthorizedListener: (() => void) | null = null

export function onUnauthorized(listener: () => void) {
  unauthorizedListener = listener
}

// A 401 means the token is dead — expired after its 30 days, or signed with a
// secret that has since changed. Kept, it would be sent forever, so it goes and
// the app falls back to the login screen.
function unauthorized(): UnauthorizedError {
  clearToken()
  unauthorizedListener?.()
  return new UnauthorizedError()
}

/**
 * Ask the server whether the token is still good, logging out if not.
 *
 * Needed because most of the app talks over the socket, and a socket refused
 * at connect only reports "error" — the same as being offline. One HTTP request
 * tells the two apart.
 */
export async function checkAuth(): Promise<void> {
  if (!getToken()) return
  const res = await fetch("/api/layout", { headers: authHeaders() }).catch(() => null)
  if (res?.status === 401) unauthorized()
}

export function getToken(): string | null {
  const token = localStorage.getItem(TOKEN_KEY)
  if (token) return token

  // A login from before the move. Carried over once rather than asking again.
  const old = sessionStorage.getItem(TOKEN_KEY)
  if (old) {
    localStorage.setItem(TOKEN_KEY, old)
    sessionStorage.removeItem(TOKEN_KEY)
  }
  return old
}

export function setToken(token: string) {
  localStorage.setItem(TOKEN_KEY, token)
}

export function clearToken() {
  localStorage.removeItem(TOKEN_KEY)
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
  if (res.status === 401) throw unauthorized()
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
  if (res.status === 401) throw unauthorized()
  if (!res.ok) throw new Error(`createSession failed: ${res.status}`)
  return res.json()
}

export async function deleteSession(id: string): Promise<void> {
  const res = await fetch(`/api/sessions/${id}`, {
    method: "DELETE",
    headers: authHeaders(),
  })
  if (res.status === 401) throw unauthorized()
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
  if (res.status === 401) throw unauthorized()
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
  if (res.status === 401) throw unauthorized()
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
  if (res.status === 401) throw unauthorized()
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
  if (res.status === 401) throw unauthorized()
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

/** A file the agent left in the session's output directory. */
export type OutputFile = AgentFile & {
  // Already announced by an earlier turn and rewritten since.
  updated: boolean
}

export function outputUrl(id: string, path: string): string {
  return `/api/agents/${id}/output/${path.split("/").map(encodeURIComponent).join("/")}`
}

/** Where an attachment can be read back. `path` is the one `store` returned. */
export function attachmentUrl(id: string, path: string): string {
  return `/api/agents/${id}/files/${encodeURIComponent(path.split("/").pop() ?? path)}`
}

// One object URL per file, for the life of the page: a transcript re-renders
// and remounts constantly, and a thumbnail must not be fetched each time.
const blobs = new Map<string, Promise<string>>()

/**
 * An authenticated file as something `<img src>` can show.
 *
 * The routes are behind the bearer token, which an `<img>` cannot send, so the
 * file is fetched and handed over as an object URL.
 */
export function blobUrl(url: string): Promise<string> {
  let p = blobs.get(url)
  if (!p) {
    p = fetch(url, { headers: authHeaders() }).then(async (res) => {
      if (res.status === 401) throw unauthorized()
      if (!res.ok) throw new Error(`${res.status}`)
      return URL.createObjectURL(await res.blob())
    })
    // A failure is kept too: the transcript re-renders on every delta, and
    // retrying each time would be a request per streamed chunk. A reload
    // starts over.
    p.catch(() => {})
    blobs.set(url, p)
  }
  return p
}

/**
 * Hand `blobUrl` a copy it already has: the image a user just attached is on
 * this device, so its bubble needs no round trip.
 */
export function seedBlobUrl(url: string, objectUrl: string) {
  if (!blobs.has(url)) blobs.set(url, Promise.resolve(objectUrl))
}

/**
 * Download one of a session's outputs.
 *
 * Fetched rather than linked: the route is behind the bearer token, and an
 * `<a href>` cannot send one. The blob is handed to a throwaway link so the
 * browser treats it as a download under the file's own name.
 */
export async function downloadAgentOutput(id: string, path: string): Promise<void> {
  const res = await fetch(outputUrl(id, path), { headers: authHeaders() })
  if (res.status === 401) throw unauthorized()
  if (res.status === 404) throw new Error("the file is no longer there")
  if (!res.ok) throw new Error(`download failed: ${res.status}`)

  const href = URL.createObjectURL(await res.blob())
  const a = document.createElement("a")
  a.href = href
  a.download = path.split("/").pop() ?? path
  document.body.appendChild(a)
  a.click()
  a.remove()
  // Revoked late: Safari reads the blob after `click()` returns.
  setTimeout(() => URL.revokeObjectURL(href), 60_000)
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
  if (res.status === 401) throw unauthorized()
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
  if (res.status === 401) throw unauthorized()
  if (!res.ok) throw new Error(`getLayout failed: ${res.status}`)
  return res.json()
}

export async function putLayout(layout: Layout): Promise<Layout> {
  const res = await fetch("/api/layout", {
    method: "PUT",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify(layout),
  })
  if (res.status === 401) throw unauthorized()
  if (!res.ok) throw new Error(`putLayout failed: ${res.status}`)
  return res.json()
}
