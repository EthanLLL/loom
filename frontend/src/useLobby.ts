import { useCallback, useEffect, useMemo, useState } from "react"
import { getSocket } from "./socket"
import type { AgentInfo } from "./api"

type Lobby = {
  sessions: AgentInfo[]
  loaded: boolean
  // For the caller's own create/delete, so the sidebar does not wait for the
  // push. The push still arrives and is merged by `seq`.
  upsert: (session: AgentInfo) => void
  drop: (id: string) => void
}

/**
 * The session list, pushed over the `agents` channel instead of polled.
 *
 * The join reply is the whole list, and phoenix.js fires the join's "ok" again
 * on every rejoin — so a reconnect replaces the list wholesale and nothing
 * missed while offline needs replaying. Between joins, each session pushes its
 * summary whenever its header changes.
 *
 * A summary can arrive older than the copy we hold (the server subscribes
 * before it reads the list), so the higher `seq` wins.
 */
export function useLobby(enabled: boolean): Lobby {
  const [byId, setById] = useState<Map<string, AgentInfo>>(new Map())
  const [loaded, setLoaded] = useState(false)

  const upsert = useCallback((session: AgentInfo) => {
    setById((current) => {
      const known = current.get(session.id)
      if (known && known.seq > session.seq) return current
      const next = new Map(current)
      next.set(session.id, session)
      return next
    })
  }, [])

  const drop = useCallback((id: string) => {
    setById((current) => {
      if (!current.has(id)) return current
      const next = new Map(current)
      next.delete(id)
      return next
    })
  }, [])

  useEffect(() => {
    if (!enabled) return

    let joined = false
    // Torn down before the join resolved. phoenix.js skips the leave push for a
    // channel still joining, which would leave the server side subscribed; see
    // the same dance in `useAgent`.
    let leaveWhenJoined = false

    const channel = getSocket().channel("agents")
    channel.on("session", upsert)
    channel.on("removed", ({ id }: { id: string }) => drop(id))

    channel
      .join()
      .receive("ok", ({ sessions }: { sessions: AgentInfo[] }) => {
        joined = true
        if (leaveWhenJoined) {
          channel.leave()
          return
        }
        setById(new Map(sessions.map((s) => [s.id, s])))
        setLoaded(true)
      })
      // Nothing to show either way; an empty list beats "connecting…" forever.
      .receive("error", () => setLoaded(true))

    return () => {
      if (joined) channel.leave()
      else leaveWhenJoined = true
    }
  }, [enabled, upsert, drop])

  // Most recently active first, so the conversation you are in stays on top.
  const sessions = useMemo(
    () => [...byId.values()].sort((a, b) => lastActive(b) - lastActive(a)),
    [byId],
  )
  return { sessions, loaded, upsert, drop }
}

export const lastActive = (s: AgentInfo) => s.last_active_at ?? s.created_at
