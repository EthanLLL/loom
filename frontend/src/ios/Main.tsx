import { useEffect, useState } from "react"
import {
  checkAuth,
  createAgent,
  deleteAgent,
  getToken,
  moveAgent,
  onUnauthorized,
  renameAgent,
  type AgentBackend,
} from "../api"
import { Chat } from "../Chat"
import { filed } from "../directories"
import { Login } from "../Login"
import { obj, post, str, useNativeAction, usePost } from "../native"
import { usePush } from "../push"
import { Search } from "../Search"
import { SettingsDialog } from "../Settings"
import { dropSocket } from "../socket"
import { useLobby } from "../useLobby"
import { NativeTerminals } from "./Terminals"

const ACTIVE_KEY = "loom_native_session"
const BACKENDS: AgentBackend[] = ["claude_code", "codex", "kiro"]

/**
 * The iOS app's main web view (native.ts): one conversation, chosen by the
 * app, and the lobby the app's session list is drawn from. Sign-in, search and
 * settings stay pages of their own; everything else on screen is the app's.
 */
export function NativeMain() {
  const [authed, setAuthed] = useState(!!getToken())
  const push = usePush(authed)
  const { sessions, devices, apps, directoryOrder, upsertDevice, loaded, upsert, drop, search } = useLobby(authed)
  const [activeId, setActiveId] = useState<string | null>(() => localStorage.getItem(ACTIVE_KEY))
  const [searching, setSearching] = useState(false)
  const [settingsOpen, setSettingsOpen] = useState(false)

  useEffect(() => {
    onUnauthorized(() => {
      dropSocket()
      setAuthed(false)
    })
    void checkAuth()
  }, [])

  // On a session that is there: the one last open, else the newest, and
  // away from one deleted here or on another device.
  useEffect(() => {
    if (!loaded) return
    setActiveId((current) =>
      current && sessions.some((s) => s.id === current) ? current : (sessions[0]?.id ?? null),
    )
  }, [loaded, sessions])
  useEffect(() => {
    if (activeId) localStorage.setItem(ACTIVE_KEY, activeId)
  }, [activeId])

  usePost({ auth: authed && loaded })
  usePost(
    {
      lobby: {
        active: activeId,
        directories: filed(sessions, directoryOrder),
        // Newest first, as useLobby keeps them.
        sessions: sessions.map((s) => ({
          id: s.id,
          title: s.title ?? s.id,
          backend: s.backend,
          status: s.status,
          directory: s.directory ?? "",
          active: s.last_active_at ?? s.created_at,
          queued: s.queued,
        })),
        apps,
      },
    },
    authed && loaded,
  )

  useNativeAction("select", (id) => setActiveId(str(id)))
  useNativeAction("create", async (backend) => {
    const b = str(backend) as AgentBackend
    if (!BACKENDS.includes(b)) return
    const session = await createAgent(b)
    upsert(session)
    setActiveId(session.id)
  })
  useNativeAction("rename", async (value) => {
    const { id, title } = obj(value)
    if (str(title).trim() !== "") upsert(await renameAgent(str(id), str(title).trim()))
  })
  useNativeAction("move", async (value) => {
    const { id, directory } = obj(value)
    upsert(await moveAgent(str(id), str(directory)))
  })
  // The app asked first; the history does not come back.
  useNativeAction("delete", async (id) => {
    await deleteAgent(str(id))
    drop(str(id))
  })
  useNativeAction("search", () => setSearching(true))
  useNativeAction("settings", () => setSettingsOpen((open) => !open))

  if (!authed) return <Login onSuccess={() => setAuthed(true)} />
  if (!loaded)
    return (
      <div className="flex h-dvh items-center justify-center bg-background font-sans text-muted-foreground">
        Connecting…
      </div>
    )

  const active = sessions.find((s) => s.id === activeId) ?? null

  return (
    <div className="app flex min-h-dvh flex-col bg-background font-sans text-foreground">
      {active ? (
        <Chat
          key={active.id}
          session={active}
          terminalOpen={false}
          terminalCount={0}
          onToggleTerminal={() => {}}
          canvasOpen={false}
          onToggleCanvas={() => {}}
          // The canvas is the app's other web view; it is told through here.
          onOpenCanvas={(item) => post({ canvas: { session: active.id, item } })}
          onFilesChanged={(outputs) => post({ files: { session: active.id, outputs } })}
        />
      ) : (
        <div className="m-auto text-muted-foreground">No session yet.</div>
      )}
      <NativeTerminals />
      <SettingsDialog
        open={settingsOpen}
        onOpenChange={setSettingsOpen}
        push={push}
        vim={null}
        devices={devices}
        onUpsertDevice={upsertDevice}
      />
      {searching && (
        <Search sessions={sessions} search={search} onOpen={setActiveId} onClose={() => setSearching(false)} />
      )}
    </div>
  )
}
