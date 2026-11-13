import { ClockIcon } from "lucide-react"
import { memo } from "react"
import { Badge } from "@/components/ui/badge"
import { Bubble, BubbleContent } from "@/components/ui/bubble"
import { Button } from "@/components/ui/button"
import { CodeBlock, CodeBlockContent } from "@/components/ui/code-block"
import { Message, MessageContent, MessageFooter } from "@/components/ui/message"
import type { CronJob, TimelineItem } from "../agent"
import { Markdown, codeSpan } from "../markdown"
import { useChat } from "./context"
import { OutputFiles, SentFiles } from "./Files"
import { formatTokens, when } from "./format"
import { Trace } from "@/components/ui/trace"
import { Thinking, ToolCard, ToolRun } from "./Tools"

/**
 * One entry in the conversation, re-rendered only when it changed.
 *
 * The timeline is rebuilt from the transcript on every event and every
 * streamed chunk, so each item is a fresh object every time — but what is in
 * it comes from the events, which do not change once they have arrived. Without
 * this, each chunk of a reply re-rendered the whole conversation, markdown and
 * all, which on a long one is most of the time a phone spends.
 */
export const Item = memo(ItemView, (a, b) => same(a.item, b.item))

// Structural equality that is cheap for timeline items: what they hold is
// mostly the very objects and strings of the events, so `===` settles nearly
// every comparison before any walking happens.
function same(a: unknown, b: unknown): boolean {
  if (a === b) return true
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false
    return a.every((x, i) => same(x, b[i]))
  }
  if (Array.isArray(b)) return false
  const ka = Object.keys(a)
  if (ka.length !== Object.keys(b).length) return false
  const ra = a as Record<string, unknown>
  const rb = b as Record<string, unknown>
  return ka.every((k) => k in rb && same(ra[k], rb[k]))
}

function ItemView({ item }: { item: TimelineItem }) {
  switch (item.kind) {
    case "user":
      return <UserMessage item={item} />

    case "assistant":
      // The only place markdown is rendered. Tool output and the user's own
      // words are shown verbatim — see `markdown.tsx`.
      return (
        <Message>
          <MessageContent
            className={
              "text-base leading-relaxed" +
              // The caret is how a live stream differs from a finished reply.
              (item.streaming
                ? " after:animate-pulse after:text-primary after:content-['▌']"
                : "")
            }
          >
            <Markdown text={item.text} />
          </MessageContent>
        </Message>
      )

    case "thinking":
      return (
        <Trace>
          <Thinking item={item} />
        </Trace>
      )

    // Every call is inside a stretch (see `foldTools`); this is for the type.
    case "tool":
      return (
        <Trace>
          <ToolCard item={item} />
        </Trace>
      )

    case "tools":
      return <ToolRun item={item} />

    case "question":
      return <Question item={item} />

    case "outputs":
      return <OutputFiles files={item.files} more={item.more} />

    case "turn":
      return <TurnLine item={item} />

    case "error":
      return (
        <div className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm whitespace-pre-wrap text-destructive">
          {item.text}
        </div>
      )

    case "notice":
      return <div className="text-sm whitespace-pre-wrap text-muted-foreground">{item.text}</div>

    case "retry":
      return (
        <div className="text-sm whitespace-pre-wrap text-muted-foreground italic">{item.text}</div>
      )

    case "cron":
      return <CronJobs jobs={item.jobs} />
  }
}

function UserMessage({ item }: { item: Extract<TimelineItem, { kind: "user" }> }) {
  const tags = [
    item.queued && <Badge key="queued" variant="secondary">queued</Badge>,
    item.origin === "phone" && <Badge key="phone" variant="secondary">phone</Badge>,
    item.origin === "cron" && (
      <Badge key="cron" variant="secondary">
        <ClockIcon /> cron
      </Badge>
    ),
  ].filter(Boolean)

  return (
    // Optimistic: shown the instant you hit enter, replaced by the
    // authoritative event a moment later.
    <Message align="end" className={item.pending ? "opacity-55" : undefined}>
      <MessageContent>
        {item.text.trim() !== "" && (
          <Bubble align="end" variant="muted">
            <BubbleContent className="text-base">
              <Rich text={item.text} />
            </BubbleContent>
          </Bubble>
        )}
        {item.files.length > 0 && (
          <div className="flex justify-end">
            <SentFiles files={item.files} />
          </div>
        )}
        {(tags.length > 0 || item.at) && (
          <MessageFooter className="gap-1.5">
            {tags}
            {item.at && <Clock at={item.at} />}
          </MessageFooter>
        )}
      </MessageContent>
    </Message>
  )
}

function Question({ item }: { item: Extract<TimelineItem, { kind: "question" }> }) {
  const { answer } = useChat()
  return (
    <div className="flex flex-col gap-3 rounded-xl border bg-card p-4 text-base leading-relaxed text-card-foreground">
      <div>
        <Rich text={item.question} />
      </div>
      {item.options.length > 0 && (
        <div className="flex flex-wrap gap-2">
          {/* The model supplies options precisely so the answer is one
              click; typing them back out would waste that. */}
          {item.options.map((o) => (
            <Button key={o} variant="outline" onClick={() => answer(o)}>
              {o}
            </Button>
          ))}
        </div>
      )}
    </div>
  )
}

// A quiet end-of-turn marker. Worth a line because it is where the context
// number in the header came from.
function TurnLine({ item }: { item: Extract<TimelineItem, { kind: "turn" }> }) {
  const context =
    item.contextTokens > 0
      ? item.contextWindow
        ? `${formatTokens(item.contextTokens)} / ${formatTokens(item.contextWindow)}`
        : `${formatTokens(item.contextTokens)} ctx`
      : null
  return (
    <div className="self-center text-xs text-muted-foreground tabular-nums">
      <Clock at={item.at} />
      {context && ` · ${context}`}
    </div>
  )
}

// A message's time: just the clock today, the date as well before that. The
// full timestamp is on hover.
function Clock({ at }: { at: number }) {
  const date = new Date(at)
  const today = date.toDateString() === new Date().toDateString()
  const text = date.toLocaleString(undefined, {
    ...(today ? {} : { month: "short", day: "numeric" }),
    ...(date.getFullYear() === new Date().getFullYear() ? {} : { year: "numeric" }),
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  })
  return (
    <time className="tabular-nums" dateTime={date.toISOString()} title={date.toLocaleString()}>
      {text}
    </time>
  )
}

/** `/cron`: one small card per scheduled job. */
function CronJobs({ jobs }: { jobs: CronJob[] }) {
  if (jobs.length === 0) return <div className="text-sm text-muted-foreground">No scheduled jobs.</div>

  return (
    <div className="flex flex-col gap-2">
      {jobs.map((job) => (
        <div key={job.id} className="rounded-lg border bg-card px-3 py-2 text-sm" title={job.prompt}>
          <div className="flex items-baseline gap-2">
            <span className="font-medium">{job.name}</span>
            <code className={codeSpan}>{job.cron}</code>
            <span className="text-xs text-muted-foreground">UTC</span>
          </div>
          <div className="text-xs text-muted-foreground">
            → {job.target_title ?? job.target} · next {when(job.next_at)}
            {job.last_run_at && <> · last {when(job.last_run_at)}</>}
          </div>
          {job.last_error && <div className="text-xs text-destructive">{job.last_error}</div>}
          <div className="font-mono text-xs text-muted-foreground">{job.id}</div>
        </div>
      ))}
    </div>
  )
}

/**
 * Fenced blocks and inline code, nothing else.
 *
 * Used for the *user's* messages and for a question's prompt — text that was
 * typed by a person, where turning a `*` into emphasis would be rewriting what
 * they wrote. Assistant messages go through `Markdown` instead.
 */
function Rich({ text }: { text: string }) {
  const parts = text.split("```")

  return (
    <>
      {parts.map((part, i) =>
        i % 2 === 1 ? (
          <CodeBlock key={i} size="sm" className="my-2">
            <CodeBlockContent>{part.replace(/^[\w+-]*\n/, "")}</CodeBlockContent>
          </CodeBlock>
        ) : (
          <span className="whitespace-pre-wrap" key={i}>
            {part.split("`").map((piece, j) =>
              j % 2 === 1 ? (
                <code key={j} className={codeSpan}>
                  {piece}
                </code>
              ) : (
                <span key={j}>{piece}</span>
              ),
            )}
          </span>
        ),
      )}
    </>
  )
}
