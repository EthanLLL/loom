import type { AgentInfo } from "./api"

/**
 * Directories as S3 has them: nothing but the prefixes on the sessions. One
 * exists while a session is in it, and is gone once the last of them moves
 * out — so there is nothing here to create or keep in step. The server's half
 * is `Loom.Agent.Directory`. The sidebar keeps them one level deep (see
 * `dirName`); a deeper path from before is listed whole.
 */

export const ROOT = ""

export const join = (dir: string, name: string) => (dir === ROOT ? name : `${dir}/${name}`)

/** The directories sessions are in, as the sidebar lists them, sorted. */
export function filed(sessions: AgentInfo[]): string[] {
  const dirs = new Set(sessions.map((s) => s.directory ?? ROOT).filter((d) => d !== ROOT))
  return [...dirs].sort((a, b) => a.localeCompare(b))
}
