// The parts of noVNC's RFB that `Vnc.tsx` uses; the package ships no types.
declare module "@novnc/novnc" {
  export default class RFB extends EventTarget {
    constructor(
      target: HTMLElement,
      urlOrChannel: string | WebSocket | RTCDataChannel,
      options?: { wsProtocols?: string[] },
    )
    scaleViewport: boolean
    clipViewport: boolean
    dragViewport: boolean
    background: string
    sendKey(keysym: number, code: string | null, down?: boolean): void
    sendCredentials(credentials: { username?: string; password?: string; target?: string }): void
    focus(): void
    disconnect(): void
  }
}
