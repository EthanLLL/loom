import { useState } from "react"
import { deviceIce, devicePortUrl, deviceRtc, type Device } from "./api"
import { ScreenPane } from "./Screen"
import { VncPane, type VncLine } from "./Vnc"

// loom-mac-screen, H.264; macOS's Screen Sharing, VNC, when that isn't there.
const SCREEN_PORT = 5960
const VNC_PORT = 5900

// For the STUN servers to answer (or, given a relay, the relay): until a
// little after the first does, or the most it is waited. Some never answer from some networks
// (stun.miwifi.com from a home line), and waiting for all of them held the
// offer up the whole time.
const GATHER_MS = 2_000
const SRFLX_GRACE_MS = 300
const OPEN_MS = 8_000

/**
 * One of the user's devices, its own screen: Connect in the Devices dialog.
 * loom-mac-screen's video when the Mac has it, Screen Sharing's VNC when it
 * doesn't. Either is a port on the device, reached directly when the two
 * networks let a WebRTC line through (node/rtc.go), or through loom's TURN
 * relay when it has one (lib/loom/turn.ex), so the screen doesn't go round
 * by loom; through loom otherwise (`LoomWeb.DevicePortSocket`).
 */
export function Desktop({
  device,
  ...pane
}: {
  device: Device
  narrow: boolean
  maximized: boolean
  onToggleMaximized: () => void
  onClose: () => void
}) {
  const [vnc, setVnc] = useState(false)
  if (vnc) return <VncPane title={device.name} open={() => line(device.id, VNC_PORT)} login={device.id} {...pane} />
  return <ScreenPane title={device.name} open={() => line(device.id, SCREEN_PORT)} onMissing={() => setVnc(true)} {...pane} />
}

async function line(id: string, port: number): Promise<VncLine> {
  const direct = await directLine(id, port)
  if (direct) {
    const { note, kind } = await classify(direct.pc)
    return { channel: direct.dc, note, kind, close: () => direct.pc.close() }
  }
  return { channel: devicePortUrl(id, port), note: "via loom", kind: "narrow" }
}

/**
 * The kind of line WebRTC chose, from its candidate pair: relayed, across
 * the internet, or on the Mac's own network — the far side at a private,
 * link-local or unique-local address, or an IPv6 one in this side's /64.
 * Chrome hides this side's host addresses behind mDNS names, so with none to
 * compare a round trip of a few milliseconds says the same.
 */
async function classify(pc: RTCPeerConnection): Promise<{ note: string; kind: "lan" | "wan" }> {
  const stats = await pc.getStats()
  let pair: RTCIceCandidatePairStats | undefined
  stats.forEach((s) => {
    if (s.type === "transport" && s.selectedCandidatePairId) pair = stats.get(s.selectedCandidatePairId)
  })
  if (!pair) stats.forEach((s) => s.type === "candidate-pair" && s.nominated && s.state === "succeeded" && (pair = s))
  const local = pair && stats.get(pair.localCandidateId)
  const remote = pair && stats.get(pair.remoteCandidateId)
  if (!local || !remote) return { note: "direct", kind: "wan" }
  if (local.candidateType === "relay" || remote.candidateType === "relay") return { note: "relayed", kind: "wan" }
  const far: string = remote.address ?? ""
  const near: string = local.address ?? ""
  const lan =
    /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|f[cd]|fe80:)/i.test(far) ||
    (far.includes(":") && near.includes(":") && prefix64(far) === prefix64(near)) ||
    (far.includes(":") && !near.includes(":") && (pair!.currentRoundTripTime ?? 1) < 0.01)
  return lan ? { note: "direct · LAN", kind: "lan" } : { note: "direct", kind: "wan" }
}

function prefix64(ip: string): string {
  const [head, tail] = ip.toLowerCase().split("::")
  const high = head ? head.split(":") : []
  const low = tail ? tail.split(":") : []
  const groups = tail === undefined ? high : [...high, ...Array(8 - high.length - low.length).fill("0"), ...low]
  return groups.slice(0, 4).map((g) => parseInt(g, 16)).join(":")
}

/**
 * A data channel straight to the device, or null when no way through was
 * found in time. What the device itself refuses (nothing on the port) is
 * thrown: going through loom would meet the same refusal.
 */
async function directLine(id: string, port: number): Promise<{ pc: RTCPeerConnection; dc: RTCDataChannel } | null> {
  const { stun, turn } = await deviceIce()
  const pc = new RTCPeerConnection({ iceServers: [{ urls: stun }, ...turn] })
  try {
    const dc = pc.createDataChannel(`tcp:${port}`)
    await pc.setLocalDescription(await pc.createOffer())
    await gathered(pc, turn.length ? "relay" : "srflx")

    let answer: string
    try {
      answer = (await deviceRtc(id, pc.localDescription!.sdp, port)).sdp
    } catch (e) {
      // 504: a loom-node from before direct lines, which has no relay either.
      if ((e as Error).message === "the device did not answer")
        throw new Error("This device's loom-node is too old for Connect: reinstall it from Devices (… → Install).")
      throw e
    }
    await pc.setRemoteDescription({ type: "answer", sdp: answer })
    return (await opened(pc, dc)) ? { pc, dc } : close(pc)
  } catch (e) {
    pc.close()
    throw e
  }
}

function close(pc: RTCPeerConnection): null {
  pc.close()
  return null
}

// Every candidate, or what there is SRFLX_GRACE_MS after the first of `kind`
// (an address a STUN server saw, or one on the relay), or after GATHER_MS.
function gathered(pc: RTCPeerConnection, kind: RTCIceCandidateType): Promise<void> {
  if (pc.iceGatheringState === "complete") return Promise.resolve()
  return new Promise((resolve) => {
    let grace: ReturnType<typeof setTimeout> | undefined
    const done = () => {
      if (pc.iceGatheringState === "complete") finish()
    }
    const found = (e: RTCPeerConnectionIceEvent) => {
      if (e.candidate?.type === kind && !grace) grace = setTimeout(finish, SRFLX_GRACE_MS)
    }
    const finish = () => {
      clearTimeout(timer)
      clearTimeout(grace)
      pc.removeEventListener("icegatheringstatechange", done)
      pc.removeEventListener("icecandidate", found)
      resolve()
    }
    const timer = setTimeout(finish, GATHER_MS)
    pc.addEventListener("icegatheringstatechange", done)
    pc.addEventListener("icecandidate", found)
  })
}

function opened(pc: RTCPeerConnection, dc: RTCDataChannel): Promise<boolean> {
  return new Promise((resolve) => {
    const finish = (ok: boolean) => {
      clearTimeout(timer)
      dc.removeEventListener("open", onOpen)
      pc.removeEventListener("connectionstatechange", onState)
      resolve(ok)
    }
    const onOpen = () => finish(true)
    const onState = () => {
      if (pc.connectionState === "failed" || pc.connectionState === "closed") finish(false)
    }
    const timer = setTimeout(() => finish(false), OPEN_MS)
    dc.addEventListener("open", onOpen)
    pc.addEventListener("connectionstatechange", onState)
  })
}
