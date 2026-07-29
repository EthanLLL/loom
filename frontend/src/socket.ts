import { Socket } from "phoenix"
import { getToken } from "./api"

// One shared socket for the whole app; each terminal is a channel on it.
// Relative URL → same-origin, proxied to Phoenix by Vite in dev. The auth
// token is sent as a connect param and verified in UserSocket.connect.
let socket: Socket | null = null

export function getSocket(): Socket {
  if (!socket) {
    socket = new Socket("/socket", { params: { token: getToken() } })
    socket.connect()
  }
  return socket
}
