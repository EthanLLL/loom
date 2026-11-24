import { getToken } from "./api"
import { VncPane } from "./Vnc"

/**
 * Loom's own browser — the Chromium that agents drive over CDP — shown here so
 * the user can take it over: log in to a site once, get past a check that
 * wants a human. Over VNC: `LoomWeb.VncSocket` carries it, noVNC draws it.
 *
 * Mounted only while shown, so a closed pane holds no connection open.
 */
export function Browser(props: {
  narrow: boolean
  maximized: boolean
  onToggleMaximized: () => void
  onClose: () => void
}) {
  const open = async () => {
    const proto = location.protocol === "https:" ? "wss:" : "ws:"
    return { channel: `${proto}//${location.host}/browser/vnc?token=${encodeURIComponent(getToken() ?? "")}` }
  }
  return <VncPane title="Browser" open={open} native="browser" {...props} />
}
