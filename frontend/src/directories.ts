import type { AgentInfo } from "./api"

/**
 * Directories as S3 has them: nothing but the prefixes on the sessions. One
 * exists while a session's path is it or is under it, and is gone once the
 * last of them moves out — so there is nothing here to create or keep in step.
 * The server's half is `Loom.Agent.Directory`.
 */

export const ROOT = ""

export const join = (dir: string, name: string) => (dir === ROOT ? name : `${dir}/${name}`)
export const basename = (dir: string) => dir.slice(dir.lastIndexOf("/") + 1)
export const parent = (dir: string) => (dir.includes("/") ? dir.slice(0, dir.lastIndexOf("/")) : ROOT)
export const within = (path: string, dir: string) =>
  dir === ROOT || path === dir || path.startsWith(dir + "/")

/** As the server will store it: segments trimmed, empty ones dropped. */
export const normalize = (typed: string) =>
  typed
    .split("/")
    .map((s) => s.trim())
    .filter((s) => s !== "")
    .join("/")

/** Every directory there is, parents included, sorted. */
export function allDirectories(sessions: AgentInfo[]): string[] {
  const dirs = new Set<string>()
  for (const s of sessions) {
    const parts = (s.directory ?? ROOT).split("/").filter(Boolean)
    for (let i = 1; i <= parts.length; i++) dirs.add(parts.slice(0, i).join("/"))
  }
  return [...dirs].sort((a, b) => a.localeCompare(b))
}

/** What is directly inside `dir`: its subdirectories by name, then its sessions. */
export function listing(sessions: AgentInfo[], dir: string): { dirs: string[]; sessions: AgentInfo[] } {
  const dirs = new Set<string>()
  const here: AgentInfo[] = []
  for (const s of sessions) {
    const path = s.directory ?? ROOT
    if (path === dir) here.push(s)
    else if (within(path, dir)) {
      const rest = dir === ROOT ? path : path.slice(dir.length + 1)
      dirs.add(join(dir, rest.split("/")[0]))
    }
  }
  return { dirs: [...dirs].sort((a, b) => a.localeCompare(b)), sessions: here }
}

/** Where `path` goes when the directory `from` becomes `to`, or null if not under it. */
export function rebase(path: string, from: string, to: string): string | null {
  if (path === from) return to
  if (path.startsWith(from + "/")) return join(to, path.slice(from.length + 1))
  return null
}
