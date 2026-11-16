import { useEffect, useState } from "react"
import { listModels, setAgentModel, type AgentInfo, type ModelOption } from "../api"
import { obj, str, useNativeAction, usePost } from "../native"
import type { Attachments } from "../useAttachments"

// The app's own name for each attachment it sent, by the tray's key: it keeps
// the thumbnail it made under that name.
const refs = new Map<string, string>()

/**
 * The composer, when the iOS app draws it (`ios/Loom/Composer.swift`): this
 * says what it shows — the conversation, whether a turn runs, the models and
 * the attachments on their way — and takes what it sends. The attachments go
 * through the page's own tray, so an upload outlives switching sessions here
 * just as it does in a browser.
 */
export function NativeComposer({
  session,
  status,
  busy,
  attachments,
  onSubmit,
  onInterrupt,
}: {
  session: AgentInfo
  status: string
  busy: boolean
  attachments: Attachments
  onSubmit: (text: string) => void
  onInterrupt: () => void
}) {
  const [models, setModels] = useState<ModelOption[]>([])
  useEffect(() => {
    let live = true
    listModels(session.backend).then((list) => live && setModels(list))
    return () => {
      live = false
    }
  }, [session.backend])

  usePost({
    chat: {
      id: session.id,
      title: session.title ?? session.id,
      backend: session.backend,
      status,
      busy,
      model: session.model ?? null,
      models,
      attachments: attachments.items.map((a) => ({
        key: a.key,
        ref: refs.get(a.key) ?? null,
        name: a.name,
        type: a.type,
        uploading: a.file === null && a.error === null,
        error: a.error,
      })),
    },
  })

  useNativeAction("submit", (value) => {
    const { session: id, text } = obj(value)
    if (id === session.id) onSubmit(str(text).trim())
  })
  useNativeAction("interrupt", onInterrupt)
  useNativeAction("attach", (value) => {
    const { name, type, data, ref } = obj(value)
    const bytes = Uint8Array.from(atob(str(data)), (c) => c.charCodeAt(0))
    const [key] = attachments.add([new File([bytes], str(name) || "attachment", { type: str(type) })])
    if (key && str(ref)) refs.set(key, str(ref))
  })
  useNativeAction("unattach", (key) => attachments.remove(str(key)))
  useNativeAction("model", (id) => {
    if (str(id) !== "") setAgentModel(session.id, str(id)).catch(() => {})
  })

  return null
}
