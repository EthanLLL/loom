import { useCallback, useEffect, useRef, useState } from "react"
import type { Channel } from "phoenix"
import { getSocket } from "./socket"
import type { AgentFile } from "./api"
import {
  addPending,
  applyDelta,
  applyEvent,
  applySnapshot,
  emptyTranscript,
  newClientMsgId,
  type AgentDelta,
  type AgentEvent,
  type Snapshot,
  type Transcript,
} from "./agent"

// Shown as the `origin` on messages so a transcript read on one device says
// where each message was typed.
const DEVICE = /Mobi|Android|iPhone|iPad/i.test(navigator.userAgent)
  ? "phone"
  : "desktop"

type Agent = {
  transcript: Transcript
  joinError: string | null
  submit: (text: string, files?: AgentFile[]) => void
  interrupt: () => void
  dropQueued: (index: number) => void
  rename: (title: string) => void
}

/**
 * Own one `agent:<id>` channel.
 *
 * Rejoin is the interesting part. Params are passed as a *function* so
 * phoenix.js re-evaluates them on every rejoin, which means a reconnect asks
 * for `since_seq` = the last seq we actually saw and gets only the gap. The
 * reply is then merged rather than replacing state, because on a rejoin it is
 * a gap and not the whole transcript.
 */
export function useAgent(
  sessionId: string | null,
  // Called for each event as it happens — never for history replayed on join,
  // so a reaction to it (opening the canvas) fires once, on the device that
  // was watching, and not again on every reload.
  onLiveEvent?: (event: AgentEvent) => void,
): Agent {
  const onLiveRef = useRef(onLiveEvent)
  onLiveRef.current = onLiveEvent
  const [transcript, setTranscript] = useState<Transcript>(emptyTranscript)
  const [joinError, setJoinError] = useState<string | null>(null)
  const channelRef = useRef<Channel | null>(null)
  // Read inside the params closure on rejoin, so it must not be state.
  const lastSeqRef = useRef(0)

  useEffect(() => {
    setTranscript(emptyTranscript)
    setJoinError(null)
    lastSeqRef.current = 0
    if (!sessionId) return

    let joined = false
    // Set if the effect is torn down before the join resolves; see the cleanup.
    let leaveWhenJoined = false

    const channel = getSocket().channel(`agent:${sessionId}`, () => ({
      since_seq: lastSeqRef.current,
      device: DEVICE,
    }))
    channelRef.current = channel

    // Two joins overlap whenever an effect is torn down before its join
    // resolves — StrictMode does this on every mount — and phoenix.js dispatches
    // an incoming message to *every* channel object matching the topic. So a
    // handler belonging to a channel we have already replaced must do nothing;
    // `delta_seq` would catch the duplicate anyway, but not touching state at
    // all is cheaper and keeps the reducer honest.
    const current = () => channelRef.current === channel

    channel.on("event", (event: AgentEvent) => {
      if (!current()) return
      const fresh = event.seq > lastSeqRef.current
      lastSeqRef.current = Math.max(lastSeqRef.current, event.seq)
      setTranscript((t) => applyEvent(t, event))
      if (fresh) onLiveRef.current?.(event)
    })

    channel.on("delta", (delta: AgentDelta) => {
      if (!current()) return
      setTranscript((t) => applyDelta(t, delta))
    })

    channel
      .join()
      .receive("ok", (snapshot: Snapshot) => {
        lastSeqRef.current = Math.max(lastSeqRef.current, snapshot.last_seq)
        const wasJoined = joined
        joined = true
        if (leaveWhenJoined || channelRef.current !== channel) {
          channel.leave()
          return
        }
        setTranscript((t) => applySnapshot(snapshot, wasJoined ? t : undefined))
        setJoinError(null)
      })
      .receive("error", (resp: { reason?: string }) =>
        setJoinError(resp?.reason ?? "join failed"),
      )
      .receive("timeout", () => setJoinError("join timed out"))

    return () => {
      // phoenix.js silently *skips* the leave push when the channel has not
      // finished joining — it fakes a local "ok" and closes its own copy — so
      // the server keeps the channel, keeps it subscribed, and keeps pushing to
      // this socket. React StrictMode mounts, unmounts and remounts every
      // effect, so in dev that happened on every single session open: two
      // server channels, every delta delivered twice.
      if (joined) {
        channel.leave()
      } else {
        leaveWhenJoined = true
      }

      channelRef.current = null
      // The socket is shared with the terminal; never disconnect it here.
    }
  }, [sessionId])

  const submit = useCallback((text: string, files: AgentFile[] = []) => {
    const channel = channelRef.current
    if (!channel) return

    const clientMsgId = newClientMsgId()
    // Optimistic: the bubble appears now and is replaced by the authoritative
    // `:user` event, matched on `client_msg_id`. Without that id the sender
    // would see its own message twice.
    setTranscript((t) => addPending(t, { clientMsgId, text, files }))

    channel
      .push("submit", {
        text,
        client_msg_id: clientMsgId,
        // Already uploaded; only the path travels. The server checks it is one
        // of this session's own attachments before the model is told about it.
        files: files.map((f) => ({ path: f.path, name: f.name })),
      })
      .receive("error", (resp: { reason?: string }) => {
        setTranscript((t) => ({
          ...t,
          pending: t.pending.filter((p) => p.clientMsgId !== clientMsgId),
        }))
        setJoinError(resp?.reason ?? "submit failed")
      })
  }, [])

  // Stopping parks the queue rather than draining it, so nothing is optimistic
  // here: the server sends the resting state and the parked list.
  const interrupt = useCallback(() => {
    channelRef.current?.push("interrupt", {})
  }, [])

  const dropQueued = useCallback((index: number) => {
    channelRef.current?.push("drop_queued", { index })
  }, [])

  const rename = useCallback((title: string) => {
    channelRef.current?.push("rename", { title })
  }, [])

  return { transcript, joinError, submit, interrupt, dropQueued, rename }
}
