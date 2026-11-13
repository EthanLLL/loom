// Text helpers for the conversation: token counts, tool summaries, times.

export function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(n >= 10_000_000 ? 0 : 1)}M`
  if (n >= 1000) return `${Math.round(n / 1000)}K`
  return String(n)
}

// The backends compact themselves, so this is information rather than a
// warning — but seeing it climb is how you know a compaction is coming.
export function contextPressure(t: {
  contextTokens: number
  contextWindow: number | null
}): "hot" | "warm" | null {
  if (!t.contextWindow) return null
  const used = t.contextTokens / t.contextWindow
  if (used >= 0.9) return "hot"
  if (used >= 0.7) return "warm"
  return null
}

/** One line saying what a tool call was about: the command, the file, the query. */
export function toolSummary(name: string, input: Record<string, unknown>): string {
  const str = (key: string) => String(input[key] ?? "")

  switch (name) {
    // Claude Code
    case "Bash":
      return str("command")
    case "Read":
    case "Write":
    case "Edit":
    case "NotebookEdit":
      return str("file_path")
    case "Glob":
      return str("pattern")
    case "Grep":
      return str("pattern") + (input.path ? ` in ${str("path")}` : "")
    case "WebFetch":
      return str("url")
    case "Task":
    case "Agent":
      return str("description")
    case "Skill":
      return str("skill")

    // Codex
    case "shell":
      return (input.cwd ? `${str("cwd")} ` : "") + str("command")
    case "apply_patch":
      return patchFiles(str("patch")).join(", ") || changedFiles(input) || "patch"
    case "web_search":
      return str("query")

    default:
      return Object.keys(input).length > 0 ? formatInput(input) : ""
  }
}

// Codex reports a patch as structured changes rather than an envelope.
function changedFiles(input: Record<string, unknown>): string {
  const changes = input.changes
  if (!Array.isArray(changes)) return ""
  return changes
    .map((c) =>
      c && typeof c === "object" ? String((c as Record<string, unknown>).path ?? "") : "",
    )
    .filter((p) => p !== "")
    .join(", ")
}

// The envelope names every file it touches on its own header lines, which is a
// far better one-line summary than the first 80 characters of a diff.
function patchFiles(patch: string): string[] {
  const files: string[] = []
  for (const line of patch.split("\n")) {
    const m = /^\*\*\* (?:Add|Update|Delete) File: (.+)$/.exec(line.trim())
    if (m) files.push(m[1])
  }
  return files
}

export function formatInput(input: Record<string, unknown>): string {
  const entries = Object.entries(input)
  if (entries.length === 1 && typeof entries[0][1] === "string") {
    return entries[0][1] as string
  }
  return JSON.stringify(input, null, 2)
}

export function extension(name: string): string {
  const dot = name.lastIndexOf(".")
  return dot > 0 && dot < name.length - 1 ? name.slice(dot + 1).slice(0, 5).toUpperCase() : "FILE"
}

// A cron job's next and last runs, in local time; the expression itself is
// UTC, and says so.
export const when = (iso: string | null) =>
  iso
    ? new Date(iso).toLocaleString(undefined, {
        month: "short",
        day: "numeric",
        weekday: "short",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
      })
    : "never"
