import { createContext, type ReactNode } from "react"

/**
 * How a link into the session's output directory is rendered.
 *
 * The agent is asked to write `[name](output/<path>)` for files it made (see
 * `Loom.Agent.Output`). That is not a URL the browser can follow — the file is
 * behind the API's token — so whoever renders the conversation supplies the
 * element, and without one such a link is shown like any other.
 */
export const OutputLink = createContext<
  ((path: string, label: ReactNode) => ReactNode) | null
>(null)
