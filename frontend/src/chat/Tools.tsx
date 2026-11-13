import {
  BotIcon,
  BrainIcon,
  FilePenIcon,
  FileTextIcon,
  GlobeIcon,
  ListChecksIcon,
  SearchIcon,
  SparklesIcon,
  TerminalIcon,
  WrenchIcon,
  type LucideIcon,
} from "lucide-react"
import { useState, type ReactNode } from "react"
import { CodeBlock, CodeBlockContent } from "@/components/ui/code-block"
import {
  Trace,
  TraceCollapsible,
  TraceCollapsibleContent,
  TraceCollapsibleTrigger,
  TraceDescription,
  TraceIcon,
  TraceLine,
  TraceTitle,
} from "@/components/ui/trace"
import type { TimelineItem } from "../agent"
import { formatInput, toolSummary } from "./format"

type Tool = Extract<TimelineItem, { kind: "tool" }>
type Thought = Extract<TimelineItem, { kind: "thinking" }>
type Run = Extract<TimelineItem, { kind: "tools" }>

// What a tool does, by name, across the backends.
const ICONS: Record<string, LucideIcon> = {
  Bash: TerminalIcon,
  shell: TerminalIcon,
  Read: FileTextIcon,
  Write: FilePenIcon,
  Edit: FilePenIcon,
  NotebookEdit: FilePenIcon,
  apply_patch: FilePenIcon,
  Glob: SearchIcon,
  Grep: SearchIcon,
  WebFetch: GlobeIcon,
  WebSearch: GlobeIcon,
  web_search: GlobeIcon,
  Task: BotIcon,
  Agent: BotIcon,
  Skill: SparklesIcon,
}

// How much of a running tool's output shows: the end of it, where a build or a
// test run says what it is doing now.
const LIVE_LINES = 12

// A new step slides in from below as the previous one leaves, so a line that
// changes reads as progress rather than flicker.
const ENTER = "animate-in fade-in slide-in-from-bottom-2 duration-300 motion-reduce:animate-none"

/**
 * A stretch of tool calls as one line; see `foldTools`.
 *
 * While the agent is in it, the line is the step under way — the call that is
 * running, or its thinking — and is replaced as each new one starts. Once it
 * is over, one call stays itself and several say how many and which. Either
 * way it opens to what is inside: a lone call's input and output, or every
 * call, each opening to its own.
 */
export function ToolRun({ item }: { item: Run }) {
  const steps = item.steps
  const latest = steps[steps.length - 1]
  const lone = steps.length === 1 && latest.kind === "tool" ? latest : null
  // Which tools, in the order first used: "Bash, Read" says more than a count.
  const names = [...new Set(steps.flatMap((s) => (s.kind === "tool" ? [s.name] : [])))]

  const count =
    item.tools > 1 ? (
      <TraceDescription>
        {item.tools} tools
        {item.failed > 0 && <span className="ml-1.5 text-destructive">{item.failed} failed</span>}
      </TraceDescription>
    ) : null

  const line = item.live ? (
    <StepLine key={latest.key} step={latest} className={ENTER} after={count} />
  ) : lone ? (
    <StepLine step={lone} />
  ) : (
    <TraceLine>
      <TraceIcon>
        <ListChecksIcon />
      </TraceIcon>
      <TraceTitle>
        Used {item.tools} tool{item.tools === 1 ? "" : "s"}
        <span className="ml-2 text-muted-foreground/70">{names.join(", ")}</span>
        {item.failed > 0 && (
          // One bad `grep` out of twelve is not the whole stretch failing,
          // so it is said on the line rather than turning it red.
          <span className="ml-2 text-destructive">{item.failed} failed</span>
        )}
      </TraceTitle>
    </TraceLine>
  )

  // Thinking under way with nothing else yet has nothing to open.
  const empty = steps.every((s) => s.kind === "thinking" && s.text.trim() === "")
  const running = item.live && latest.kind === "tool" && !latest.result ? latest : null

  return (
    <Trace>
      {empty ? (
        line
      ) : (
        <TraceCollapsible>
          <TraceCollapsibleTrigger>{line}</TraceCollapsibleTrigger>
          <TraceCollapsibleContent className="flex flex-col gap-2">
            {lone ? (
              <ToolDetails tool={lone} />
            ) : (
              steps.map((step) =>
                step.kind === "tool" ? (
                  <ToolCard key={step.key} item={step} />
                ) : step.kind === "thinking" && step.text.trim() !== "" ? (
                  <Thinking key={step.key} item={step} />
                ) : null,
              )
            )}
          </TraceCollapsibleContent>
        </TraceCollapsible>
      )}
      {running && <LiveOutput tool={running} />}
    </Trace>
  )
}

/** One step's line: a call's name and what it was about, or the thinking. */
function StepLine({
  step,
  className,
  after,
}: {
  step: TimelineItem
  className?: string
  after?: ReactNode
}) {
  if (step.kind === "thinking") {
    return (
      <TraceLine status={step.streaming ? "running" : undefined} className={className}>
        <TraceIcon>
          <BrainIcon />
        </TraceIcon>
        <TraceTitle>{step.streaming ? "Thinking" : "Thought"}</TraceTitle>
        {after}
      </TraceLine>
    )
  }
  if (step.kind !== "tool") return null

  const Icon = ICONS[step.name] ?? WrenchIcon
  const summary = toolSummary(step.name, step.input)
  const failed = step.result !== null && !step.result.ok
  return (
    <TraceLine status={step.result ? (failed ? "error" : undefined) : "running"} className={className}>
      <TraceIcon>
        <Icon />
      </TraceIcon>
      <TraceTitle>
        <span className="font-medium">{step.name}</span>
        {summary && <span className="ml-2 font-mono text-[0.8125rem]">{summary}</span>}
      </TraceTitle>
      {after}
    </TraceLine>
  )
}

/**
 * Output streaming out of a running call, the end of it. For liveness only and
 * may be partial — Codex coalesces chunks — so once the call finishes its
 * result is what is kept.
 */
function LiveOutput({ tool }: { tool: Tool }) {
  const tail = tool.streamed.trimEnd().split("\n").slice(-LIVE_LINES).join("\n")
  if (tail === "") return null
  return (
    <CodeBlock size="sm" className="border-l-2 border-l-primary">
      <CodeBlockContent wrap className="max-h-64">
        {tail}
      </CodeBlockContent>
    </CodeBlock>
  )
}

/** A call's input and output, verbatim: a diff or a log means nothing reflowed. */
function ToolDetails({ tool }: { tool: Tool }) {
  const output = tool.result ? tool.result.output : tool.streamed
  const failed = tool.result !== null && !tool.result.ok
  return (
    <>
      {Object.keys(tool.input).length > 0 && (
        <CodeBlock size="sm">
          <CodeBlockContent wrap className="max-h-64">
            {formatInput(tool.input)}
          </CodeBlockContent>
        </CodeBlock>
      )}
      {output.trim() !== "" && (
        <CodeBlock size="sm" variant={failed ? "destructive" : "default"}>
          <CodeBlockContent wrap className="max-h-96">
            {output}
          </CodeBlockContent>
        </CodeBlock>
      )}
    </>
  )
}

/** One call inside an opened stretch, opening in turn to its input and output. */
export function ToolCard({ item }: { item: Tool }) {
  const output = item.result ? item.result.output : item.streamed
  if (Object.keys(item.input).length === 0 && output.trim() === "") return <StepLine step={item} />

  return (
    <TraceCollapsible>
      <TraceCollapsibleTrigger>
        <StepLine step={item} />
      </TraceCollapsibleTrigger>
      <TraceCollapsibleContent className="flex flex-col gap-2">
        <ToolDetails tool={item} />
      </TraceCollapsibleContent>
    </TraceCollapsible>
  )
}

/**
 * The model's thinking, as a line that opens into the text. Opus returns
 * thinking blocks with empty text under the default display, so a bare line is
 * the normal case rather than an edge case.
 */
export function Thinking({ item }: { item: Thought }) {
  const text = item.text.trim()
  // Open while it streams, so the words show as they come; then it folds.
  const [open, setOpen] = useState<boolean | undefined>(undefined)

  const line = (
    <TraceLine status={item.streaming ? "running" : undefined}>
      <TraceIcon>
        <BrainIcon />
      </TraceIcon>
      <TraceTitle>{item.streaming ? "Thinking" : text ? "Thought" : "Thought for a moment"}</TraceTitle>
    </TraceLine>
  )

  if (text === "") return line

  return (
    <TraceCollapsible open={open ?? item.streaming} onOpenChange={setOpen}>
      <TraceCollapsibleTrigger>{line}</TraceCollapsibleTrigger>
      <TraceCollapsibleContent className="whitespace-pre-wrap">{text}</TraceCollapsibleContent>
    </TraceCollapsible>
  )
}
