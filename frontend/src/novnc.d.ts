// The parts of noVNC's RFB that `Browser.tsx` uses; the package ships no types.
declare module "@novnc/novnc" {
  export default class RFB extends EventTarget {
    constructor(target: HTMLElement, url: string, options?: { wsProtocols?: string[] })
    scaleViewport: boolean
    clipViewport: boolean
    dragViewport: boolean
    background: string
    sendKey(keysym: number, code: string | null, down?: boolean): void
    disconnect(): void
  }
}
