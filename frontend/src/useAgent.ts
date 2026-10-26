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

// The last few sessions' transcripts, kept when their chat unmounts so going
// back to one shows it at once and the join asks only for what came since.
// Memory only, and bounded: a long transcript is a few megabytes of objects.
const CACHED_SESSIONS = 8
const cache = new Map<string, Transcript>()

function remember(id: string, t: Transcript) {
  cache.delete(id)
  // Nothing in flight survives a remount: streaming placeholders are dropped
  // by the join anyway, and a pending bubble's ack may never come to this mount.
  cache.set(id, { ...t, streaming: [], toolStreams: [], lastDeltaSeq: 0, pending: [] })
  for (const old of cache.keys()) {
    if (cache.size <= CACHED_SESSIONS) break
    cache.delete(old)
  }
}

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
  // Straight from the cache on the first render, so there is no empty frame.
  const [transcript, setTranscript] = useState<Transcript>(
    () => (sessionId && cache.get(sessionId)) || emptyTranscript,
  )
  const [joinError, setJoinError] = useState<string | null>(null)
  const channelRef = useRef<Channel | null>(null)
  // Read inside the params closure on rejoin, so it must not be state.
  const lastSeqRef = useRef(0)
  // For the cache, written on unmount.
  const transcriptRef = useRef(transcript)
  transcriptRef.current = transcript
  // Bumped to join again from nothing when the cache turns out to be wrong.
  const [epoch, setEpoch] = useState(0)

  useEffect(() => {
    const cached = sessionId ? cache.get(sessionId) : undefined
    setTranscript(cached ?? emptyTranscript)
    setJoinError(null)
    lastSeqRef.current = cached?.lastSeq ?? 0
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
        const wasJoined = joined
        joined = true
        if (leaveWhenJoined || channelRef.current !== channel) {
          channel.leave()
          return
        }
        // Behind what we hold: not a gap but a different history (the session
        // was replaced under the same id). The cache is no use; start over.
        if (snapshot.last_seq < lastSeqRef.current) {
          cache.delete(sessionId)
          channelRef.current = null
          channel.leave()
          setEpoch((e) => e + 1)
          return
        }
        // A gap like a rejoin's, from the cache too — unless the server has
        // since dropped events we never saw. Then the reply is everything it
        // still keeps, and merging would hide the hole.
        const hole =
          snapshot.truncated_before !== null && lastSeqRef.current < snapshot.truncated_before
        const merge = (wasJoined || !!cached) && !hole
        lastSeqRef.current = snapshot.last_seq
        setTranscript((t) => applySnapshot(snapshot, merge ? t : undefined))
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
      // Only a transcript the server has filled; an unjoined mount holds
      // nothing worth keeping, and must not replace what the cache has.
      if (joined && transcriptRef.current.lastSeq > 0) remember(sessionId, transcriptRef.current)
      // The socket is shared with the terminal; never disconnect it here.
    }
  }, [sessionId, epoch])

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
