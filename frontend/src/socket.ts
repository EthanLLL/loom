import { Socket } from "phoenix"
import { checkAuth, getToken } from "./api"

// One shared socket for the whole app; each terminal is a channel on it.
// Relative URL → same-origin, proxied to Phoenix by Vite in dev. The auth
// token is sent as a connect param and verified in UserSocket.connect.
let socket: Socket | null = null

// A refused connect looks exactly like being offline, and phoenix.js retries
// either way. So on an error, ask over HTTP — at most this often, since the
// retries come every few seconds.
const CHECK_INTERVAL_MS = 10_000
let lastCheck = 0

export function getSocket(): Socket {
  if (!socket) {
    // A function, so a reconnect sends whatever token is current rather than
    // the one there was when the socket was made.
    socket = new Socket("/socket", { params: () => ({ token: getToken() }) })
    socket.onError(() => {
      const now = Date.now()
      if (now - lastCheck < CHECK_INTERVAL_MS) return
      lastCheck = now
      void checkAuth()
    })
    socket.connect()
    probeOnResume(socket)
  }
  return socket
}

// Away for less than this and the socket is trusted as it is.
const AWAY_MS = 3_000
// How long a probe may go unanswered before the socket is called dead.
const PROBE_TIMEOUT_MS = 2_000

/**
 * Check the socket the moment the app comes back, rather than waiting for the
 * heartbeat to notice.
 *
 * iOS freezes a backgrounded PWA, and the WebSocket it comes back with often
 * still says OPEN although the server dropped it long ago. phoenix.js only
 * reconnects on its own when the socket is *not* connected, so a zombie like
 * that is found out by the heartbeat: up to 30s until the next one, and another
 * 30s for it to time out — a minute of a conversation that looks live and
 * receives nothing. A ping answered within two seconds settles it either way;
 * an unanswered one gets the reconnect straight away, and each channel's rejoin
 * then fetches only what it missed (`since_seq`, see `useAgent`).
 */
function probeOnResume(s: Socket) {
  let hiddenAt = document.hidden ? Date.now() : 0
  let probing = false

  const probe = () => {
    // Not connected is phoenix.js's own case: it reconnects on visibility.
    if (probing || !s.isConnected()) return
    probing = true
    let answered = false
    s.ping(() => {
      answered = true
    })
    setTimeout(() => {
      probing = false
      if (!answered && s.isConnected()) restart(s)
    }, PROBE_TIMEOUT_MS)
  }

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) hiddenAt = Date.now()
    else if (Date.now() - hiddenAt > AWAY_MS) probe()
  })
  // Back from the bfcache, or the network came back: same doubt.
  window.addEventListener("pageshow", (e) => e.persisted && probe())
  window.addEventListener("online", probe)
}

// The private half of phoenix.js (1.8) this needs, typed here so a change to it
// shows up as a type error rather than as a silent no-op.
type SocketInternals = {
  closeWasClean: boolean
  triggerChanError(): void
  teardown(callback: () => void, code?: number, reason?: string): void
  reconnectTimer: { scheduleTimeout(): void }
}

/**
 * What phoenix.js itself does on a heartbeat timeout. Not `disconnect()` and
 * `connect()`: a zombie's close event may never fire, and then the channels are
 * never told they lost the server — they would sit "joined" on a fresh socket
 * that has none of them, and never rejoin.
 */
function restart(s: Socket) {
  const internals = s as unknown as SocketInternals
  internals.triggerChanError()
  internals.closeWasClean = false
  internals.teardown(() => internals.reconnectTimer.scheduleTimeout(), 1000, "probe timeout")
}

/** Close the socket, so the next `getSocket()` starts clean. On logout. */
export function dropSocket() {
  socket?.disconnect()
  socket = null
}
