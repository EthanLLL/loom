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
  }
  return socket
}

/** Close the socket, so the next `getSocket()` starts clean. On logout. */
export function dropSocket() {
  socket?.disconnect()
  socket = null
}
