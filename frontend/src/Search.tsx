import { Search as SearchIcon } from "lucide-react"
import { useEffect, useMemo, useRef, useState } from "react"
import type { AgentInfo, SearchHit } from "./api"
import { ago } from "./format"
import { fuzzyFilter } from "./fuzzy"
import { isComposing } from "./ime"
import { lastActive } from "./useLobby"

// Long enough to let a word be typed, short enough to feel live.
const DEBOUNCE_MS = 200
const TITLES = 30

type Row = { kind: "title"; session: AgentInfo } | { kind: "hit"; session: AgentInfo; hit: SearchHit }

/**
 * Telescope's layout: the prompt at the bottom, the best match right above it.
 *
 * Two kinds of result. Titles are filtered here on every keystroke, fuzzily
 * (`fuzzy.ts`) — including while an IME is composing, since a Chinese IME is
 * also how English gets typed. What was said is searched on the server by rg
 * (`Loom.Search`), a pause after the last keystroke and never mid-composition:
 * the half-typed pinyin is not what is being looked for.
 *
 * Arrows or C-n / C-p choose, Enter opens, Esc closes.
 */
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

  useEffect(() => input.current?.focus(), [])

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
        : fuzzyFilter(q, sessions, (s) => s.title ?? s.id)
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
    <div className="modal-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal search" role="dialog" aria-label="Search">
        {/* Reversed, so the first row sits right above the prompt. */}
        <div className="search-results">
          {rows.map((row, i) => (
            <div
              key={row.kind === "hit" ? `${row.hit.id}:${row.hit.seq}` : row.session.id}
              ref={i === sel ? (el) => el?.scrollIntoView({ block: "nearest" }) : undefined}
              className={"search-row" + (i === sel ? " selected" : "")}
              onMouseEnter={() => setSel(i)}
              onClick={() => open(row)}
            >
              <div className="search-row-head">
                <span className={"dot " + row.session.status} />
                <span className="session-label">{row.session.title ?? row.session.id}</span>
                {row.session.directory && <span className="search-dir">{row.session.directory}</span>}
                <span className="session-when">
                  {ago(row.kind === "hit" ? row.hit.at : lastActive(row.session))}
                </span>
              </div>
              {row.kind === "hit" && (
                <div className={"search-snippet " + row.hit.kind}>
                  {row.hit.kind === "user" ? "› " : ""}
                  {row.hit.before}
                  <mark>{row.hit.match}</mark>
                  {row.hit.after}
                </div>
              )}
            </div>
          ))}
          {rows.length === 0 && <div className="search-empty">Nothing found.</div>}
        </div>
        {error && <div className="picker-error">Search failed: {error}</div>}
        <label className="search-prompt">
          <SearchIcon />
          <input
            ref={input}
            className="picker-input"
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
              } else if (e.key === "Escape") {
                e.preventDefault()
                onClose()
              }
            }}
          />
        </label>
      </div>
    </div>
  )
}
