import { useState } from "react"
import { devicePortUrl, deviceRtc, type Device } from "./api"
import { ScreenPane } from "./Screen"
import { VncPane, type VncLine } from "./Vnc"

// loom-mac-screen, H.264; macOS's Screen Sharing, VNC, when that isn't there.
const SCREEN_PORT = 5960
const VNC_PORT = 5900

// For learning the address the internet sees each side at. Reachable from
// mainland China as well as outside it; a server that doesn't answer only
// costs its share of the wait.
const STUN = ["stun:stun.miwifi.com:3478", "stun:stun.chat.bilibili.com:3478", "stun:stun.cloudflare.com:3478"]

// For the STUN servers to answer: until a little after the first does, or
// the most it is waited. Some never answer from some networks
// (stun.miwifi.com from a home line), and waiting for all of them held the
// offer up the whole time.
const GATHER_MS = 2_000
const SRFLX_GRACE_MS = 300
const OPEN_MS = 8_000

/**
 * One of the user's devices, its own screen: Connect in the Devices dialog.
 * loom-mac-screen's video when the Mac has it, Screen Sharing's VNC when it
 * doesn't. Either is a port on the device, reached directly when the two
 * networks let a WebRTC line through (node/rtc.go), so the screen doesn't go
 * round by loom; through loom otherwise (`LoomWeb.DevicePortSocket`).
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
  if (direct) return { channel: direct.dc, note: "direct", close: () => direct.pc.close() }
  return { channel: devicePortUrl(id, port), note: "via loom" }
}

/**
 * A data channel straight to the device, or null when no way through was
 * found in time. What the device itself refuses (nothing on the port) is
 * thrown: going through loom would meet the same refusal.
 */
async function directLine(id: string, port: number): Promise<{ pc: RTCPeerConnection; dc: RTCDataChannel } | null> {
  const pc = new RTCPeerConnection({ iceServers: [{ urls: STUN }] })
  try {
    const dc = pc.createDataChannel(`tcp:${port}`)
    await pc.setLocalDescription(await pc.createOffer())
    await gathered(pc)

    let answer: string
    try {
      answer = (await deviceRtc(id, pc.localDescription!.sdp, port, STUN)).sdp
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

// Every candidate, or what there is SRFLX_GRACE_MS after the first address a
// STUN server saw, or after GATHER_MS.
function gathered(pc: RTCPeerConnection): Promise<void> {
  if (pc.iceGatheringState === "complete") return Promise.resolve()
  return new Promise((resolve) => {
    let grace: ReturnType<typeof setTimeout> | undefined
    const done = () => {
      if (pc.iceGatheringState === "complete") finish()
    }
    const found = (e: RTCPeerConnectionIceEvent) => {
      if (e.candidate?.type === "srflx" && !grace) grace = setTimeout(finish, SRFLX_GRACE_MS)
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
