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

/**
 * The directories sessions are in, as the sidebar lists them: first those in
 * `order`, as the user dragged them (`Loom.Agent.DirectoryOrder`, the same on
 * every device), then the rest in code point order. Not `localeCompare`,
 * which would follow each browser's language, pinyin on a Chinese one, and
 * differ between devices.
 */
export function filed(sessions: AgentInfo[], order: string[]): string[] {
  const dirs = new Set(sessions.map((s) => s.directory ?? ROOT).filter((d) => d !== ROOT))
  const rank = new Map(order.map((d, i) => [d, i]))
  const at = (d: string) => rank.get(d) ?? Infinity
  return [...dirs].sort((a, b) => at(a) - at(b) || (a < b ? -1 : a > b ? 1 : 0))
}

/** `dirs` with `dir` taken out and put back at `index` of what is left. */
export function moved(dirs: string[], dir: string, index: number): string[] {
  const rest = dirs.filter((d) => d !== dir)
  return [...rest.slice(0, index), dir, ...rest.slice(index)]
}
