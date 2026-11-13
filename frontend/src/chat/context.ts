import { createContext, useContext } from "react"
import type { CanvasItem } from "../canvasItems"

/**
 * What a card or link deep in the transcript needs from the conversation it is
 * in: which session its files belong to, how to show something in the canvas,
 * and how to answer the agent (a question's option is one click).
 *
 * A context rather than props because the transcript nests — a folded group of
 * tool calls holds more items — and every level would otherwise pass all
 * three along. The value is stable for a session, so the memoised items
 * underneath are not re-rendered by it.
 */
export type ChatScope = {
  sessionId: string
  openCanvas: (item: CanvasItem) => void
  answer: (text: string) => void
}

export const ChatContext = createContext<ChatScope | null>(null)

export function useChat(): ChatScope {
  const scope = useContext(ChatContext)
  if (!scope) throw new Error("useChat outside a conversation")
  return scope
}
