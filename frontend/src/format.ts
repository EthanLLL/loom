export function formatBytes(n: number): string {
  if (n >= 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`
  if (n >= 1024) return `${Math.round(n / 1024)} KB`
  return `${n} B`
}

/** Which engine, in the two letters the sidebar and the chat's header show. */
export function backendShort(backend: string): string {
  return ({ claude_code: "cc", codex: "cx" } as Record<string, string>)[backend] ?? backend
}
