export class UnauthorizedError extends Error {
  constructor() {
    super("unauthorized")
    this.name = "UnauthorizedError"
  }
}

// Token lives in localStorage, so it survives the app being closed. On iOS the
// only way to reload a home-screen web app is to kill it, and sessionStorage
// made every reload a password prompt. The server signs a device out after two
// weeks unused, or when it is removed from Settings → Sign-in.
const TOKEN_KEY = "loom_token"

// Who to tell when the server stops accepting the token. Set once by `App`.
let unauthorizedListener: (() => void) | null = null

export function onUnauthorized(listener: () => void) {
  unauthorizedListener = listener
}

// A 401 means the token is dead — its device unused for two weeks or signed
// out, or signed with a secret that has since changed. Kept, it would be sent forever, so it goes and
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
  const res = await fetch("/api/auth", { headers: authHeaders() }).catch(() => null)
  if (res?.status === 401) unauthorized()
  // A token from before per-device logins comes back with one of its own.
  if (res?.ok) {
    const data: AuthOverview = await res.json()
    if (data.token) setToken(data.token)
  }
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

/** Password, plus a code from the authenticator once one is set up. */
export async function login(password: string, code?: string): Promise<string> {
  const res = await fetch("/api/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ password, code }),
  })
  if (res.status === 401) throw new Error("invalid_password")
  if (res.status === 429) throw new Error("locked")
  if (!res.ok) throw new Error(`login failed: ${res.status}`)
  const data = await res.json()
  setToken(data.token)
  return data.token
}

// ── Passkeys and the authenticator; see `Loom.Auth` ─────────────────────

export type AuthOptions = { passkey: boolean; totp: boolean }

export type Passkey = {
  id: string
  name: string
  rp_id: string
  created_at: string
  last_used_at: string | null
}

export type Login = {
  id: string
  name: string
  method: string
  ip: string | null
  created_at: string
  last_seen_at: string
}

export type AuthOverview = {
  passkeys: Passkey[]
  totp: { created_at: string; recovery_left: number } | null
  logins: Login[]
  idle_days: number
  current: string
  token?: string
}

/** What the sign-in page offers. */
export async function authOptions(): Promise<AuthOptions> {
  const res = await fetch("/api/auth/options")
  if (!res.ok) throw new Error(`authOptions failed: ${res.status}`)
  return res.json()
}

/** Whether this browser can make or use a passkey at all. */
export function passkeysSupported(): boolean {
  return typeof window.PublicKeyCredential === "function"
}

const b64url = {
  encode(buf: ArrayBuffer): string {
    let s = ""
    for (const b of new Uint8Array(buf)) s += String.fromCharCode(b)
    return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
  },
  decode(text: string): Uint8Array<ArrayBuffer> {
    const s = atob(text.replace(/-/g, "+").replace(/_/g, "/"))
    const out = new Uint8Array(s.length)
    for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i)
    return out
  },
}

/**
 * Sign in with a passkey: Face ID, Touch ID, Windows Hello, or a phone nearby.
 * No list of credentials is sent, so the browser offers whichever passkeys it
 * has for this site.
 */
export async function passkeyLogin(): Promise<string> {
  const ch = await fetch("/api/auth/passkey/challenge", { method: "POST" })
  if (!ch.ok) throw new Error(`challenge failed: ${ch.status}`)
  const { challenge } = await ch.json()

  const cred = (await navigator.credentials.get({
    publicKey: {
      challenge: b64url.decode(challenge),
      rpId: location.hostname,
      userVerification: "required",
      timeout: 120_000,
    },
  })) as PublicKeyCredential | null
  if (!cred) throw new Error("cancelled")
  const response = cred.response as AuthenticatorAssertionResponse

  const res = await fetch("/api/auth/passkey/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      id: cred.id,
      client_data: b64url.encode(response.clientDataJSON),
      authenticator_data: b64url.encode(response.authenticatorData),
      signature: b64url.encode(response.signature),
    }),
  })
  if (!res.ok) throw new Error("passkey_refused")
  const data = await res.json()
  setToken(data.token)
  return data.token
}

export async function authOverview(): Promise<AuthOverview> {
  const res = await fetch("/api/auth", { headers: authHeaders() })
  if (res.status === 401) throw unauthorized()
  if (!res.ok) throw new Error(`authOverview failed: ${res.status}`)
  return res.json()
}

/** Make a passkey on this device (or a phone nearby) and register it. */
export async function registerPasskey(): Promise<Passkey> {
  const ch = await fetch("/api/auth/passkeys/challenge", { method: "POST", headers: authHeaders() })
  if (ch.status === 401) throw unauthorized()
  if (!ch.ok) throw new Error(`challenge failed: ${ch.status}`)
  const { challenge, exclude } = (await ch.json()) as { challenge: string; exclude: string[] }

  const cred = (await navigator.credentials.create({
    publicKey: {
      challenge: b64url.decode(challenge),
      rp: { id: location.hostname, name: "Loom" },
      // One user per Loom, so a fixed handle. A device that already has one
      // says so, from `excludeCredentials`.
      user: {
        id: new TextEncoder().encode("loom"),
        name: `loom@${location.hostname}`,
        displayName: "Loom",
      },
      pubKeyCredParams: [
        { type: "public-key", alg: -7 },
        { type: "public-key", alg: -257 },
      ],
      authenticatorSelection: { residentKey: "required", userVerification: "required" },
      attestation: "none",
      excludeCredentials: exclude.map((id) => ({ type: "public-key", id: b64url.decode(id) })),
      timeout: 120_000,
    },
  })) as PublicKeyCredential | null
  if (!cred) throw new Error("cancelled")
  const response = cred.response as AuthenticatorAttestationResponse
  const publicKey = response.getPublicKey()
  if (!publicKey) throw new Error("This browser did not give the passkey's public key")

  const res = await fetch("/api/auth/passkeys", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({
      id: cred.id,
      client_data: b64url.encode(response.clientDataJSON),
      authenticator_data: b64url.encode(response.getAuthenticatorData()),
      public_key: b64url.encode(publicKey),
    }),
  })
  if (res.status === 401) throw unauthorized()
  if (!res.ok) throw new Error(`Passkey refused: ${(await res.json()).error}`)
  return (await res.json()).passkey
}

export async function deletePasskey(id: string): Promise<void> {
  await authDelete(`/api/auth/passkeys/${encodeURIComponent(id)}`)
}

/** A new authenticator secret, kept by the server until confirmed. */
export async function totpBegin(): Promise<string> {
  const res = await fetch("/api/auth/totp", { method: "POST", headers: authHeaders() })
  if (res.status === 401) throw unauthorized()
  if (!res.ok) throw new Error(`totpBegin failed: ${res.status}`)
  return (await res.json()).secret
}

/** Confirm the secret with a code from the app; returns the recovery codes. */
export async function totpConfirm(code: string): Promise<string[]> {
  const res = await fetch("/api/auth/totp/confirm", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ code }),
  })
  if (res.status === 401) throw unauthorized()
  if (res.status === 422) throw new Error("That code is not right; check the app's clock and try the next one")
  if (!res.ok) throw new Error(`totpConfirm failed: ${res.status}`)
  return (await res.json()).recovery_codes
}

export async function totpRemove(): Promise<void> {
  await authDelete("/api/auth/totp")
}

export async function revokeLogin(id: string): Promise<void> {
  await authDelete(`/api/auth/logins/${encodeURIComponent(id)}`)
}

async function authDelete(path: string): Promise<void> {
  const res = await fetch(path, { method: "DELETE", headers: authHeaders() })
  if (res.status === 401) throw unauthorized()
  if (!res.ok) throw new Error(`${path} failed: ${res.status}`)
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
  // Where the session list files it, S3-style: a path like "work/aws", or ""
  // for the root. Directories are only these prefixes; see `directories.ts`.
  directory: string
  backend: AgentBackend
  backend_label: string
  // The Claude Code profile it talks through, or null for the default.
  // Older servers do not send it.
  profile?: string | null
  // The model picked in the composer, or null for the backend's default.
  // Older servers do not send it.
  model?: string | null
  created_at: number
  // The last message either way, as ms since the epoch: what orders the
  // sidebar and what its age shows. Older servers do not send it.
  last_active_at?: number
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
// own store, so there is nothing to migrate if it changes later. So is the
// profile, which picks the model provider a Claude Code session talks to.
export async function createAgent(
  backend: AgentBackend,
  profile?: string,
): Promise<AgentInfo> {
  const res = await fetch("/api/agents", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify(profile ? { backend, profile } : { backend }),
  })
  if (res.status === 401) throw unauthorized()
  if (!res.ok) throw new Error(`createAgent failed: ${res.status}`)
  return res.json()
}

// Names of the Claude Code profiles on the server; empty when there are none.
export async function listProfiles(): Promise<string[]> {
  const res = await fetch("/api/profiles", { headers: authHeaders() })
  if (res.status === 401) throw unauthorized()
  if (!res.ok) return []
  const data = await res.json()
  return data.profiles
}

export type ModelOption = { id: string; label: string; default: boolean }

// Once per backend per page load: the list only changes with the machine's
// configuration, and the composer asks every time a session opens.
const modelLists = new Map<AgentBackend, Promise<ModelOption[]>>()

export function listModels(backend: AgentBackend): Promise<ModelOption[]> {
  let list = modelLists.get(backend)
  if (!list) {
    list = fetch(`/api/models?backend=${backend}`, { headers: authHeaders() })
      .then(async (res) => (res.ok ? (await res.json()).models : []))
      .catch(() => [])
    modelLists.set(backend, list)
    // A failure is not worth remembering; the next session asks again.
    list.then((models) => {
      if (models.length === 0) modelLists.delete(backend)
    })
  }
  return list
}

// From the next turn on; the one running finishes on the model it started with.
export async function setAgentModel(id: string, model: string): Promise<AgentInfo> {
  const res = await fetch(`/api/agents/${id}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ model }),
  })
  if (res.status === 401) throw unauthorized()
  if (!res.ok) throw new Error(`setAgentModel failed: ${res.status}`)
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

// Only the header changes: the session keeps its id, URL and files.
export async function moveAgent(id: string, directory: string): Promise<AgentInfo> {
  const res = await fetch(`/api/agents/${id}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ directory }),
  })
  if (res.status === 401) throw unauthorized()
  if (!res.ok) throw new Error(`moveAgent failed: ${res.status}`)
  return res.json()
}

// Renames a directory, or moves it with everything under it: whole paths both.
// The sessions it touches arrive over the lobby as they change.
export async function moveDirectory(from: string, to: string): Promise<void> {
  const res = await fetch("/api/directories/move", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...authHeaders() },
    body: JSON.stringify({ from, to }),
  })
  if (res.status === 401) throw unauthorized()
  if (!res.ok) throw new Error(`moveDirectory failed: ${res.status}`)
}

/** One message that matched a content search; see `Loom.Search`. */
export type SearchHit = {
  id: string
  seq: number
  at: number
  kind: "user" | "assistant_text"
  before: string
  match: string
  after: string
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

/**
 * One entry of a turn's outputs: a file directly in `output/`, or a whole
 * directory (`kind: "dir"`) however many files changed in it. A directory with
 * an `index.html` is a page for the canvas. Events from before directories were
 * grouped have no `kind` and are files.
 */
export type OutputFile = AgentFile & {
  kind?: "file" | "dir"
  // Directories only: how many files, and the page to open if there is one.
  files?: number
  index?: string | null
  // Already announced by an earlier turn and rewritten since.
  updated: boolean
}

/** One file in a session's `files/` or `output/`, as the file browser lists it. */
export type TreeFile = {
  path: string
  size: number
  // Seconds since the epoch.
  mtime: number
}

/** Everything the session holds: what the user attached, and what the agent made. */
export async function sessionTree(id: string): Promise<{ files: TreeFile[]; output: TreeFile[] }> {
  const res = await fetch(`/api/agents/${id}/tree`, { headers: authHeaders() })
  if (res.status === 401) throw unauthorized()
  if (!res.ok) throw new Error(`could not list the files: ${res.status}`)
  return res.json()
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
 * Whether a file of this type may be shown as a thumbnail. Not SVG: it is a
 * document that can carry script, and an object URL has loom's own origin — an
 * `<img>` would not run it, but "open image in new tab" would, with the login
 * token in reach.
 */
export const isThumbnail = (contentType: string | undefined) =>
  !!contentType?.startsWith("image/") && !contentType.startsWith("image/svg")

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
  await download(outputUrl(id, path), path.split("/").pop() ?? path)
}

/** One attachment, by its stored name, handed to the browser as a download. */
export async function downloadAttachment(id: string, name: string): Promise<void> {
  await download(attachmentUrl(id, name), name)
}

/** One output directory as a zip, built by the server. */
export async function downloadAgentZip(id: string, path: string): Promise<void> {
  const url = `/api/agents/${id}/zip/${path.split("/").map(encodeURIComponent).join("/")}`
  await download(url, `${path.split("/").pop() ?? path}.zip`)
}

async function download(url: string, filename: string): Promise<void> {
  const res = await fetch(url, { headers: authHeaders() })
  if (res.status === 401) throw unauthorized()
  if (res.status === 404) throw new Error("the file is no longer there")
  if (res.status === 413) throw new Error("too big to zip (over 1 GB)")
  if (!res.ok) throw new Error(`download failed: ${res.status}`)

  // Typed as opaque bytes: an HTML or SVG blob that a browser navigated to
  // instead of saving would run on loom's origin.
  const blob = new Blob([await res.blob()], { type: "application/octet-stream" })
  const href = URL.createObjectURL(blob)
  const a = document.createElement("a")
  a.href = href
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  // Revoked late: Safari reads the blob after `click()` returns.
  setTimeout(() => URL.revokeObjectURL(href), 60_000)
}

// The canvas's signed prefixes per session, re-fetched well before the
// server's one-day expiry.
export type CanvasBases = { output: string; files: string }
const canvasBases = new Map<string, { at: number; bases: Promise<CanvasBases> }>()
const CANVAS_TTL = 12 * 60 * 60 * 1000

/**
 * Where this session's outputs are served to the canvas iframe — a signed
 * `/canvas/<id>/<token>/` prefix, because an iframe cannot send the bearer
 * header — and its attachments, under `/canvas-files/<id>/<token>/`. See
 * `LoomWeb.CanvasController`.
 */
export function canvasBase(id: string): Promise<CanvasBases> {
  const cached = canvasBases.get(id)
  if (cached && Date.now() - cached.at < CANVAS_TTL) return cached.bases

  const bases = fetch(`/api/agents/${id}/canvas`, { method: "POST", headers: authHeaders() }).then(
    async (res) => {
      if (res.status === 401) throw unauthorized()
      if (!res.ok) throw new Error(`canvas failed: ${res.status}`)
      const body = await res.json()
      return { output: body.base as string, files: body.files as string }
    },
  )
  bases.catch(() => canvasBases.delete(id))
  canvasBases.set(id, { at: Date.now(), bases })
  return bases
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

/** An app, as `Loom.Apps.list/0` describes it; pushed by the lobby. */
export type AppInfo = {
  name: string
  title: string
  order: number
  url: string // on the apps' own origin, served by Caddy
  icon: string | null
}

/** One of the user's machines, as `Loom.Nodes` describes it. */
export type Device = {
  id: string
  name: string
  online: boolean
  os: string | null
  arch: string | null
  hostname: string | null
  version: string | null
  created_at: string
  last_seen_at: string | null
}

// The server words its refusals ("there is already a device called mac", "that
// name is taken"), so they are shown as they are.
async function apiCall<T>(url: string, init: RequestInit): Promise<T> {
  const res = await fetch(url, {
    ...init,
    headers: { "Content-Type": "application/json", ...authHeaders() },
  })
  if (res.status === 401) throw unauthorized()
  if (res.status === 204) return undefined as T
  const body = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(body.error ?? `request failed: ${res.status}`)
  return body
}

/** Register a device: it comes back with its one-time install code. */
export function createDevice(name: string): Promise<{ node: Device; code: string }> {
  return apiCall("/api/devices", { method: "POST", body: JSON.stringify({ name }) })
}

export function renameDevice(id: string, name: string): Promise<{ node: Device }> {
  return apiCall(`/api/devices/${id}`, { method: "PATCH", body: JSON.stringify({ name }) })
}

export function deleteDevice(id: string): Promise<void> {
  return apiCall(`/api/devices/${id}`, { method: "DELETE" })
}

/** A new install code for a device; using it replaces the device's token. */
export function deviceInstallCode(id: string): Promise<{ code: string }> {
  return apiCall(`/api/devices/${id}/install`, { method: "POST" })
}

/** What to paste into a terminal on the device. */
export function installCommand(code: string): string {
  return `curl -fsSL ${window.location.origin}/node/install/${code} | sh`
}

// ── Notifications (see push.ts) ───────────────────────────────────────────

/** The key the server signs pushes with, base64url, to subscribe against. */
export function pushKey(): Promise<{ key: string }> {
  return apiCall("/api/push", { method: "GET" })
}

export function savePushSubscription(subscription: PushSubscriptionJSON, test: boolean): Promise<void> {
  return apiCall("/api/push/subscriptions", {
    method: "POST",
    body: JSON.stringify({ subscription, origin: window.location.origin, test }),
  })
}

export function deletePushSubscription(endpoint: string): Promise<void> {
  return apiCall("/api/push/subscriptions", { method: "DELETE", body: JSON.stringify({ endpoint }) })
}

// ── Files in the canvas's tree ─────────────────────────────────────────────

/** Renamed where it is; comes back as its new path. */
export function renameOutput(id: string, path: string, name: string): Promise<{ path: string }> {
  return apiCall(outputUrl(id, path), { method: "PATCH", body: JSON.stringify({ new_name: name }) })
}

/** A file, or a directory and everything in it. */
export function deleteOutput(id: string, path: string): Promise<void> {
  return apiCall(outputUrl(id, path), { method: "DELETE" })
}

export function renameAttachment(id: string, name: string, newName: string): Promise<{ path: string }> {
  return apiCall(attachmentUrl(id, name), { method: "PATCH", body: JSON.stringify({ new_name: newName }) })
}

export function deleteAttachment(id: string, name: string): Promise<void> {
  return apiCall(attachmentUrl(id, name), { method: "DELETE" })
}

/** Either side of the tree: an output by its path, an attachment by its name. */
export function renameAgentOutputOrAttachment(
  id: string,
  source: "output" | "files",
  path: string,
  name: string,
): Promise<{ path: string }> {
  return source === "files" ? renameAttachment(id, path, name) : renameOutput(id, path, name)
}

export function deleteAgentOutputOrAttachment(
  id: string,
  source: "output" | "files",
  path: string,
): Promise<void> {
  return source === "files" ? deleteAttachment(id, path) : deleteOutput(id, path)
}
