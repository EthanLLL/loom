import { Search01Icon } from "@hugeicons/core-free-icons"
import { HugeiconsIcon } from "@hugeicons/react"
import { useEffect, useMemo, useRef, useState } from "react"
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog"
import { InputGroup, InputGroupAddon, InputGroupInput } from "@/components/ui/input-group"
import type { AgentInfo, SearchHit } from "./api"
import { join } from "./directories"
import { ago } from "./format"
import { fuzzyScore } from "./fuzzy"
import { isComposing } from "./ime"
import { WORKING } from "./Sidebar"
import { lastActive } from "./useLobby"

// Long enough to let a word be typed, short enough to feel live.
const DEBOUNCE_MS = 200
const TITLES = 30

type Row = { kind: "title"; session: AgentInfo } | { kind: "hit"; session: AgentInfo; hit: SearchHit }

/**
 * Telescope's layout: the prompt at the bottom, the best match right above it.
 *
 * Two kinds of result. Titles, with their directory, are filtered here on
 * every keystroke, fuzzily (`fuzzy.ts`) — including while an IME is composing, since a Chinese IME is
 * also how English gets typed. What was said is searched on the server by rg
 * (`Loom.Search`), a pause after the last keystroke and never mid-composition:
 * the half-typed pinyin is not what is being looked for.
 *
 * Arrows or C-n / C-p choose, Enter opens, Esc closes. The rows look like the
 * composer's `/` menu: the same list, the same highlight.
 */
/**
 * Titles matched as the whole key, S3-style — `aws/billing` for "billing" in
 * the directory `aws` — so a query can name the directory as well, the way
 * telescope matches a file's path. A session whose own title matches comes
 * before one that only matched by its directory, so typing a directory's name
 * does not bury the titles that have it in them.
 */
function byKey(q: string, sessions: AgentInfo[]): AgentInfo[] {
  return sessions
    .flatMap((s, index) => {
      const title = s.title ?? s.id
      const score = fuzzyScore(q, join(s.directory ?? "", title))
      return score === null ? [] : [{ s, index, score, own: fuzzyScore(q, title) !== null }]
    })
    .sort((a, b) => Number(b.own) - Number(a.own) || b.score - a.score || a.index - b.index)
    .map((r) => r.s)
}

export function Search({
  sessions,
  search,
  onOpen,
  onClose,
}: {
  sessions: AgentInfo[]
  search: (q: string) => Promise<SearchHit[]>
  onOpen: (id: string) => void
  onClose: () => void
}) {
  const [q, setQ] = useState("")
  const [composing, setComposing] = useState(false)
  const [hits, setHits] = useState<SearchHit[]>([])
  const [error, setError] = useState<string | null>(null)
  const [sel, setSel] = useState(0)
  const input = useRef<HTMLInputElement>(null)
  // Which request is the newest: an older answer arriving late is dropped.
  const latest = useRef(0)

  useEffect(() => {
    if (composing) return
    const term = q.trim()
    const n = ++latest.current
    if (term === "") {
      setHits([])
      setError(null)
      return
    }
    const timer = setTimeout(() => {
      search(term)
        .then((found) => {
          if (n !== latest.current) return
          setHits(found)
          setError(null)
        })
        .catch((e: Error) => n === latest.current && setError(e.message))
    }, DEBOUNCE_MS)
    return () => clearTimeout(timer)
  }, [q, composing, search])

  const byId = useMemo(() => new Map(sessions.map((s) => [s.id, s])), [sessions])
  const rows = useMemo<Row[]>(() => {
    const titled =
      q.trim() === ""
        ? [...sessions].sort((a, b) => lastActive(b) - lastActive(a))
        : byKey(q, sessions)
    const found = hits.flatMap((hit): Row[] => {
      const session = byId.get(hit.id)
      return session ? [{ kind: "hit", session, hit }] : []
    })
    return [...titled.slice(0, TITLES).map((session): Row => ({ kind: "title", session })), ...found]
  }, [q, sessions, hits, byId])

  useEffect(() => setSel(0), [q, hits])

  const open = (row: Row | undefined) => {
    if (!row) return
    onOpen(row.session.id)
    onClose()
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent
        showCloseButton={false}
        initialFocus={input}
        // Sized to what is visible, which with a keyboard up is less than the
        // screen (--app-height, viewport.ts), and centred in that.
        className="top-[calc(var(--app-height,100dvh)/2)] flex max-h-[min(36rem,calc(var(--app-height,100dvh)-2rem))] flex-col gap-2 p-2 font-sans sm:max-w-xl"
      >
        <DialogTitle className="sr-only">Search</DialogTitle>
        <DialogDescription className="sr-only">Search session titles and what was said in them.</DialogDescription>
        {/* Reversed, so the first row sits right above the prompt. */}
        <div role="listbox" className="flex min-h-0 flex-1 flex-col-reverse overflow-y-auto">
          {rows.map((row, i) => {
            const working = row.session.status === "running" || row.session.status === "starting"
            return (
              <div
                key={row.kind === "hit" ? `${row.hit.id}:${row.hit.seq}` : row.session.id}
                role="option"
                aria-selected={i === sel}
                ref={i === sel ? (el) => el?.scrollIntoView({ block: "nearest" }) : undefined}
                className="flex cursor-pointer flex-col gap-0.5 rounded-lg px-2.5 py-1.5 text-sm aria-selected:bg-accent pointer-coarse:py-2.5 pointer-coarse:text-base"
                onMouseEnter={() => setSel(i)}
                onClick={() => open(row)}
              >
                <div className="flex min-w-0 items-baseline gap-2">
                  <span className={"min-w-0 truncate" + (working ? WORKING : "")}>
                    {row.session.title ?? row.session.id}
                  </span>
                  {row.session.directory && (
                    <span className="shrink-0 text-xs text-muted-foreground">{row.session.directory}</span>
                  )}
                  <span className="ml-auto shrink-0 text-xs text-muted-foreground tabular-nums">
                    {ago(row.kind === "hit" ? row.hit.at : lastActive(row.session))}
                  </span>
                </div>
                {row.kind === "hit" && (
                  <div className="truncate text-xs text-muted-foreground">
                    {row.hit.kind === "user" ? "› " : ""}
                    {row.hit.before}
                    <mark className="rounded-sm bg-primary/20 px-0.5 text-foreground">{row.hit.match}</mark>
                    {row.hit.after}
                  </div>
                )}
              </div>
            )
          })}
          {rows.length === 0 && <div className="px-2.5 py-6 text-center text-sm text-muted-foreground">Nothing found.</div>}
        </div>
        {/* Without ripgrep on the server only titles can be searched: said
            plainly, as a note rather than an error. */}
        {error === "no_rg" ? (
          <div className="px-2.5 text-xs text-muted-foreground">
            Titles only: searching what was said needs ripgrep (rg) on the server.
          </div>
        ) : (
          error && <div className="px-2.5 text-xs text-destructive">Search failed: {error}</div>
        )}
        <InputGroup className="h-10 shrink-0 rounded-xl pointer-coarse:h-[44px]">
          <InputGroupAddon>
            <HugeiconsIcon icon={Search01Icon} />
          </InputGroupAddon>
          <InputGroupInput
            ref={input}
            // 16px or more, or iOS zooms the page when it is focused.
            className="text-base"
            placeholder="Search titles and what was said"
            value={q}
            onChange={(e) => setQ(e.target.value)}
            onCompositionStart={() => setComposing(true)}
            onCompositionEnd={() => setComposing(false)}
            onKeyDown={(e) => {
              if (isComposing(e)) return
              // Up the screen is further from the prompt, so further down the list.
              const up = e.key === "ArrowUp" || (e.ctrlKey && e.key === "p")
              const down = e.key === "ArrowDown" || (e.ctrlKey && e.key === "n")
              if (up || down) {
                e.preventDefault()
                setSel((i) => Math.max(0, Math.min(rows.length - 1, i + (up ? 1 : -1))))
              } else if (e.key === "Enter") {
                e.preventDefault()
                open(rows[sel])
              }
            }}
          />
        </InputGroup>
      </DialogContent>
    </Dialog>
  )
}
