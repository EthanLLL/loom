export function formatBytes(n: number): string {
  if (n >= 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`
  if (n >= 1024) return `${Math.round(n / 1024)} KB`
  return `${n} B`
}

/** Which engine, in the two letters the sidebar and the chat's header show. */
export function backendShort(backend: string): string {
  return ({ claude_code: "cc", codex: "cx" } as Record<string, string>)[backend] ?? backend
}

/** How long ago, as short as the session list needs: "now", "5m", "3h", "2d". */
export function ago(ms: number): string {
  const mins = Math.floor((Date.now() - ms) / 60000)
  if (mins < 1) return "now"
  if (mins < 60) return `${mins}m`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `${hours}h`
  return `${Math.floor(hours / 24)}d`
}
