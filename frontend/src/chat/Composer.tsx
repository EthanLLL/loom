import { ArrowUpIcon, ChevronDownIcon, PlusIcon, SquareIcon } from "lucide-react"
import { useEffect, useLayoutEffect, useRef, useState, type RefObject } from "react"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { InputGroup, InputGroupButton, InputGroupTextarea } from "@/components/ui/input-group"
import { listModels, setAgentModel, type AgentBackend, type ModelOption } from "../api"
import { isComposing } from "../ime"
import type { Attachments } from "../useAttachments"
import { AttachmentChip } from "./Files"

// What a message can be instead of a prompt. `/compact` goes to the backend
// (Codex's adapter turns it into an RPC); `/reload` and `/cron` are loom's own.
const COMMANDS = [
  { name: "/compact", hint: "summarize the conversation to free up context" },
  { name: "/reload", hint: "reload Claude Code, Codex and Kiro config: settings, MCP, skills" },
  { name: "/cron", hint: "list every scheduled job" },
]

// Only a message that *starts* with `/` is a command, and only while the first
// word is still being typed: a `/` later on is just text.
function commandMatches(text: string) {
  if (!text.startsWith("/") || /\s/.test(text)) return []
  return COMMANDS.filter((c) => c.name.startsWith(text))
}

// Past this the box scrolls instead of eating the conversation.
const MAX_LINES = 5

/**
 * The message box, after Gemini's: one line with the attach button on its left
 * and the model, stop and send on its right, until the text needs more. Then
 * the text takes the full width and the buttons drop to a row beneath it.
 * Attachments waiting to go sit above the text.
 */
export function Composer({
  sessionId,
  backend,
  model,
  busy,
  interrupted,
  attachments,
  onSubmit,
  onInterrupt,
}: {
  sessionId: string
  backend: AgentBackend
  model: string | null
  busy: boolean
  interrupted: boolean
  attachments: Attachments
  onSubmit: (text: string) => void
  onInterrupt: () => void
}) {
  // The draft outlives the component: switching sessions rebuilds the chat,
  // and a half-written message should be there on the way back.
  const draftKey = `loom_draft:${sessionId}`
  const [text, setText] = useState(() => localStorage.getItem(draftKey) ?? "")
  useEffect(() => {
    if (text === "") localStorage.removeItem(draftKey)
    else localStorage.setItem(draftKey, text)
  }, [draftKey, text])
  const ref = useRef<HTMLTextAreaElement>(null)
  const picker = useRef<HTMLInputElement>(null)
  // True between compositionstart and compositionend, one more guard besides
  // `isComposing` (see the Enter handler below).
  const composingRef = useRef(false)

  // The command menu: open while the text could still become a command, until
  // Escape dismisses it (typing anything brings it back).
  const [pick, setPick] = useState(0)
  const [dismissed, setDismissed] = useState<string | null>(null)
  const matches = dismissed === text ? [] : commandMatches(text)
  const selected = matches[Math.min(pick, matches.length - 1)]
  const complete = (name: string) => {
    setText(name)
    ref.current?.focus()
  }

  const [multiline, setMultiline] = useState(false)
  // How long the text was when it first wrapped. Going multiline widens the
  // box, so the same text may fit on one line again — leaving at that point
  // would flip straight back.
  const wrappedAt = useRef(0)

  // Grow with the text up to MAX_LINES, then scroll inside. Measured rather
  // than left to `field-sizing`, which not every Safari the app runs in has.
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return
    const style = getComputedStyle(el)
    const line = parseFloat(style.lineHeight)
    const padding = parseFloat(style.paddingTop) + parseFloat(style.paddingBottom)

    if (text === "") {
      // The placeholder can wrap too, and is not worth a second line.
      wrappedAt.current = 0
      setMultiline(false)
      el.style.height = ""
      return
    }

    el.style.height = "auto"
    const content = el.scrollHeight - padding

    if (!multiline && (text.includes("\n") || content > line * 1.5)) {
      wrappedAt.current = text.length
      setMultiline(true)
      return // measured again in the wider layout
    }
    if (multiline && !text.includes("\n") && text.length < wrappedAt.current) {
      setMultiline(false)
      return
    }

    el.style.height = Math.min(content, line * MAX_LINES) + padding + "px"
  }, [text, multiline])

  // An attachment on its own is a message: dragging in a screenshot and
  // pressing send, with nothing typed, is a normal way to ask about it.
  const sendable = (text.trim() !== "" || attachments.ready.length > 0) && !attachments.uploading

  const send = () => {
    if (!sendable) return
    onSubmit(text.trim())
    setText("")
  }

  return (
    // Clears the home indicator on a phone (see viewport-fit in index.html);
    // the keyboard covers it, so then the padding is just a gap.
    <div className="composer mx-auto w-full max-w-3xl shrink-0 px-4 pt-1.5 pb-[max(1rem,env(safe-area-inset-bottom))] max-sm:px-3 in-[.keyboard]:pb-2">
      <InputGroup className="relative h-auto flex-col items-stretch rounded-3xl bg-card p-1.5 shadow-xs dark:bg-card">
        {selected && (
          <ul
            role="listbox"
            className="absolute inset-x-0 bottom-full z-20 mb-2 rounded-xl bg-popover p-1 text-popover-foreground shadow-md ring-1 ring-foreground/10"
          >
            {matches.map((c) => (
              <li
                key={c.name}
                role="option"
                aria-selected={c === selected}
                className="flex cursor-pointer items-baseline gap-4 rounded-lg px-2.5 py-1.5 text-sm aria-selected:bg-accent pointer-coarse:py-2.5"
                onMouseEnter={() => setPick(matches.indexOf(c))}
                // mousedown, not click: the textarea must keep focus.
                onMouseDown={(e) => {
                  e.preventDefault()
                  complete(c.name)
                }}
              >
                <span className="font-mono">{c.name}</span>
                <span className="min-w-0 truncate text-muted-foreground">{c.hint}</span>
              </li>
            ))}
          </ul>
        )}

        {attachments.items.length > 0 && (
          // Uploaded on pick, drop or paste, so each card reports its own
          // state: a failed one stays and says why, rather than vanish.
          <div className="flex flex-wrap gap-2 p-1 pb-1.5">
            {attachments.items.map((item) => (
              <AttachmentChip key={item.key} item={item} onRemove={() => attachments.remove(item.key)} />
            ))}
          </div>
        )}

        {/* One row of three until the text wraps; then the text spans the
            row and the buttons go under it, attach left and the rest right. */}
        <div
          className={"grid grid-cols-[auto_1fr_auto] gap-x-1 gap-y-1 " + (multiline ? "items-end" : "items-center")}
          style={{
            gridTemplateAreas: multiline
              ? '"input input input" "attach . actions"'
              : '"attach input actions"',
          }}
        >
          <InputGroupTextarea
            ref={ref}
            // `.composer-input` is how the app's keys find the box (App.tsx).
            className={
              "composer-input field-sizing-fixed min-h-0 flex-none text-base leading-normal [grid-area:input] md:text-base " +
              // On one line the box is exactly a button's height (2rem, or
              // 2.75rem on touch) so the text and the buttons share a centre.
              (multiline ? "px-2.5 pt-2 pb-1.5" : "px-1.5 py-1 pointer-coarse:py-2.5")
            }
            value={text}
            rows={1}
            // Enter sends, so the phone keyboard should say so.
            enterKeyHint="send"
            placeholder={
              busy
                ? "Steer the agent mid-turn…"
                : interrupted
                  ? "Stopped — type to continue"
                  : "Message the agent…"
            }
            onChange={(e) => {
              setText(e.target.value)
              setPick(0)
              setDismissed(null)
            }}
            // A pasted screenshot is the commonest attachment there is, and it
            // never exists as a file on disk to pick.
            onPaste={(e) => {
              const files = Array.from(e.clipboardData.files)
              if (files.length === 0) return
              e.preventDefault()
              attachments.add(files)
            }}
            onCompositionStart={() => {
              composingRef.current = true
            }}
            onCompositionEnd={() => {
              composingRef.current = false
            }}
            onKeyDown={(e) => {
              if (selected && !composingRef.current && !isComposing(e)) {
                const n = matches.length
                if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                  e.preventDefault()
                  setPick((pick + (e.key === "ArrowDown" ? 1 : n - 1)) % n)
                  return
                }
                if (e.key === "Escape") {
                  e.preventDefault()
                  setDismissed(text)
                  return
                }
                // Tab, or Enter on a half-typed name, completes it; Enter on a
                // complete one falls through and sends.
                if (e.key === "Tab" || (e.key === "Enter" && !e.shiftKey && text !== selected.name)) {
                  e.preventDefault()
                  complete(selected.name)
                  return
                }
              }

              if (e.key !== "Enter" || e.shiftKey) return

              // An IME uses Enter to commit the candidate, and that keystroke
              // must not also send the message. On macOS Safari compositionend
              // fires before that keydown, so isComposing and the ref are both
              // already false; only keyCode 229 gives it away (see ime.ts). The
              // next Enter, with no composition in progress, sends.
              if (isComposing(e) || composingRef.current) return

              e.preventDefault()
              send()
            }}
          />

          <input
            ref={picker}
            type="file"
            multiple
            className="sr-only"
            tabIndex={-1}
            onChange={(e) => {
              attachments.add(Array.from(e.target.files ?? []))
              // Reset, or picking the same file twice in a row does nothing.
              e.target.value = ""
            }}
          />
          <InputGroupButton
            size="icon-sm"
            variant="ghost"
            className="rounded-full text-muted-foreground [grid-area:attach]"
            title="Attach files — or drop them anywhere in the conversation"
            aria-label="Attach files"
            onClick={() => picker.current?.click()}
          >
            <PlusIcon />
          </InputGroupButton>

          <div className="flex items-center gap-1 [grid-area:actions]">
            <ModelPicker sessionId={sessionId} backend={backend} model={model} input={ref} />

            {busy && (
              <InputGroupButton
                size="icon-sm"
                variant="secondary"
                className="rounded-full hover:text-destructive"
                onClick={onInterrupt}
                title="Stop the turn"
                aria-label="Stop the turn"
              >
                <SquareIcon className="fill-current" />
              </InputGroupButton>
            )}
            {/* While the agent works, an empty box has nothing to send and the
              stop button is the one that matters. */}
            {!(busy && !sendable) && (
              <InputGroupButton
                size="icon-sm"
                variant="default"
                className="rounded-full"
                onClick={send}
                disabled={!sendable}
                aria-label="Send"
                title={
                  attachments.uploading
                    ? "Uploading…"
                    : interrupted
                      ? "Continue"
                      : busy
                        ? "Send — it reaches the agent mid-turn"
                        : "Send"
                }
              >
                <ArrowUpIcon />
              </InputGroupButton>
            )}
          </div>
        </div>
      </InputGroup>
    </div>
  )
}

/**
 * The model for this session's next turn, switched in place; the transcript
 * says when it changed. Shows the backend's default until one is picked.
 */
function ModelPicker({
  sessionId,
  backend,
  model,
  input,
}: {
  sessionId: string
  backend: AgentBackend
  model: string | null
  input: RefObject<HTMLTextAreaElement | null>
}) {
  const [options, setOptions] = useState<ModelOption[]>([])

  useEffect(() => {
    let live = true
    listModels(backend).then((list) => live && setOptions(list))
    return () => {
      live = false
    }
  }, [backend])

  const current = options.find((o) => o.id === model) ?? options.find((o) => o.default)
  if (!current) return null

  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        render={
          <InputGroupButton
            size="sm"
            variant="ghost"
            className="text-muted-foreground"
            title="Model for the next turn"
          />
        }
      >
        {current.label}
        <ChevronDownIcon />
      </DropdownMenuTrigger>
      {/* Back to the box when it closes, which keeps a phone's keyboard up
          when the pick was made with it showing. Kiro lists twenty-odd
          models, so the list scrolls rather than run off the screen. */}
      <DropdownMenuContent align="end" side="top" className="max-h-96 w-auto min-w-44" finalFocus={input}>
        <DropdownMenuRadioGroup
          value={current.id}
          onValueChange={(id: string) => {
            if (id !== current.id) setAgentModel(sessionId, id).catch(() => {})
          }}
        >
          {options.map((o) => (
            <DropdownMenuRadioItem key={o.id} value={o.id} closeOnClick>
              {o.label}
            </DropdownMenuRadioItem>
          ))}
        </DropdownMenuRadioGroup>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
