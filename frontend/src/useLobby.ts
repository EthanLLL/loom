import { useCallback, useEffect, useMemo, useState } from "react"
import { getSocket } from "./socket"
import type { AgentInfo, Device } from "./api"

type Lobby = {
  sessions: AgentInfo[]
  // The user's machines, in the order they were added. Online state is pushed
  // as they connect and drop.
  devices: Device[]
  upsertDevice: (device: Device) => void
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
  const [devices, setDevices] = useState<Map<string, Device>>(new Map())

  // No `seq` to compare: a device's summary is only ever sent from the one
  // process that owns the registry, in order.
  const upsertDevice = useCallback((device: Device) => {
    setDevices((current) => new Map(current).set(device.id, device))
  }, [])

  const dropDevice = useCallback((id: string) => {
    setDevices((current) => {
      if (!current.has(id)) return current
      const next = new Map(current)
      next.delete(id)
      return next
    })
  }, [])

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
    channel.on("node", upsertDevice)
    channel.on("node_removed", ({ id }: { id: string }) => dropDevice(id))

    channel
      .join()
      .receive("ok", ({ sessions, nodes }: { sessions: AgentInfo[]; nodes: Device[] }) => {
        joined = true
        if (leaveWhenJoined) {
          channel.leave()
          return
        }
        setById(new Map(sessions.map((s) => [s.id, s])))
        setDevices(new Map((nodes ?? []).map((d) => [d.id, d])))
        setLoaded(true)
      })
      // Nothing to show either way; an empty list beats "connecting…" forever.
      .receive("error", () => setLoaded(true))

    return () => {
      if (joined) channel.leave()
      else leaveWhenJoined = true
    }
  }, [enabled, upsert, drop, upsertDevice, dropDevice])

  // Most recently active first, so the conversation you are in stays on top.
  const sessions = useMemo(
    () => [...byId.values()].sort((a, b) => lastActive(b) - lastActive(a)),
    [byId],
  )
  const deviceList = useMemo(
    () => [...devices.values()].sort((a, b) => a.created_at.localeCompare(b.created_at)),
    [devices],
  )
  return { sessions, devices: deviceList, upsertDevice, loaded, upsert, drop }
}

export const lastActive = (s: AgentInfo) => s.last_active_at ?? s.created_at
