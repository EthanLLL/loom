import { useCallback, useState } from "react"
import {
  authOverview,
  createDevice,
  deleteDevice,
  deletePasskey,
  deviceInstallCode,
  installCommand,
  listModels,
  quickAskSettings,
  renameDevice,
  revokeLogin,
  setQuickAsk,
  totpBegin,
  totpConfirm,
  totpRemove,
  type AuthOverview,
  type Device,
  type ModelOption,
  type QuickAsk,
} from "../api"
import { obj, str, useNativeAction, usePost } from "../native"
import { setThemePref, useThemePref, type ThemePref } from "../theme"

const THEMES: ThemePref[] = ["system", "light", "dark", "coolnight"]

/**
 * The app's Settings (Settings.swift in loom-ios) are native; this is what they
 * read and do, as Settings.tsx, Devices.tsx and Security.tsx do in a browser.
 * The app asks with `settings-*` actions; the state goes back as `settings`
 * whenever it changes. The devices come with the lobby, live. Quick Ask comes
 * with the models its backend offers.
 */
export function useNativeSettings(devices: Device[], upsertDevice: (device: Device) => void, on: boolean) {
  const theme = useThemePref()
  const [auth, setAuth] = useState<AuthOverview | null>(null)
  const [error, setError] = useState<string | null>(null)
  // A device's install command, shown once; the authenticator being set up,
  // then the recovery codes it produced, also shown once.
  const [install, setInstall] = useState<{ id: string; command: string } | null>(null)
  const [totp, setTotp] = useState<{ secret: string; uri: string } | null>(null)
  const [recovery, setRecovery] = useState<string[] | null>(null)
  const [quickAsk, setQuickAskState] = useState<(QuickAsk & { models: ModelOption[] }) | null>(null)

  const reload = useCallback(() => {
    authOverview()
      .then(setAuth)
      .catch((e) => setError((e as Error).message))
  }, [])

  const showQuickAsk = async (settings: QuickAsk) =>
    setQuickAskState({ ...settings, models: await listModels(settings.backend) })

  const run = async (action: () => Promise<unknown>, relist = false) => {
    setError(null)
    try {
      await action()
    } catch (e) {
      setError((e as Error).message)
    }
    if (relist) reload()
  }

  usePost(
    {
      settings: {
        theme,
        devices: devices.map((d) => ({
          id: d.id,
          name: d.name,
          online: d.online,
          system: d.os ? `${d.os}/${d.arch}` : "",
          hostname: d.hostname ?? "",
          seen: d.last_seen_at ? Date.parse(d.last_seen_at) / 1000 : 0,
        })),
        auth: auth && {
          current: auth.current,
          idle_days: auth.idle_days,
          totp: auth.totp && { recovery_left: auth.totp.recovery_left },
          passkeys: auth.passkeys.map((p) => ({
            id: p.id,
            name: p.name,
            created: Date.parse(p.created_at) / 1000,
            used: p.last_used_at ? Date.parse(p.last_used_at) / 1000 : 0,
          })),
          logins: auth.logins.map((l) => ({
            id: l.id,
            name: l.name,
            method: l.method,
            ip: l.ip ?? "",
            created: Date.parse(l.created_at) / 1000,
            seen: Date.parse(l.last_seen_at) / 1000,
          })),
        },
        error,
        install,
        totp,
        recovery,
        quick_ask: quickAsk && {
          backend: quickAsk.backend,
          model: quickAsk.model,
          models: quickAsk.models.map((m) => ({ id: m.id, label: m.label })),
        },
      },
    },
    on,
  )

  // Opened: what is signed in may have changed since.
  useNativeAction("settings-load", () => {
    setError(null)
    setInstall(null)
    setTotp(null)
    setRecovery(null)
    reload()
    void run(async () => showQuickAsk(await quickAskSettings()))
  })
  useNativeAction("settings-theme", (value) => {
    const pref = str(value) as ThemePref
    if (THEMES.includes(pref)) setThemePref(pref)
  })

  useNativeAction("settings-quick-ask", (value) => {
    const { backend, model } = obj(value)
    void run(async () =>
      showQuickAsk(await setQuickAsk({ backend: str(backend) as QuickAsk["backend"], model: model ? str(model) : null })),
    )
  })

  useNativeAction("settings-device-add", (value) =>
    run(async () => {
      const name = str(value).trim()
      if (name === "") return
      const { node, code } = await createDevice(name)
      upsertDevice(node)
      setInstall({ id: node.id, command: installCommand(code) })
    }),
  )
  useNativeAction("settings-device-rename", (value) => {
    const { id, name } = obj(value)
    void run(async () => upsertDevice((await renameDevice(str(id), str(name).trim())).node))
  })
  useNativeAction("settings-device-install", (value) =>
    run(async () => setInstall({ id: str(value), command: installCommand((await deviceInstallCode(str(value))).code) })),
  )
  useNativeAction("settings-device-delete", (value) =>
    run(async () => {
      await deleteDevice(str(value))
      setInstall((shown) => (shown?.id === str(value) ? null : shown))
    }),
  )
  useNativeAction("settings-install-done", () => setInstall(null))

  useNativeAction("settings-passkey-delete", (value) => run(() => deletePasskey(str(value)), true))
  useNativeAction("settings-totp-begin", () =>
    run(async () => {
      const secret = await totpBegin()
      const label = encodeURIComponent(`Loom:${location.hostname}`)
      setTotp({ secret, uri: `otpauth://totp/${label}?secret=${secret}&issuer=Loom&algorithm=SHA1&digits=6&period=30` })
    }),
  )
  useNativeAction("settings-totp-confirm", (value) =>
    run(async () => {
      setRecovery(await totpConfirm(str(value).trim()))
      setTotp(null)
    }, true),
  )
  useNativeAction("settings-totp-cancel", () => setTotp(null))
  useNativeAction("settings-recovery-done", () => setRecovery(null))
  useNativeAction("settings-totp-remove", () => run(totpRemove, true))
  useNativeAction("settings-login-revoke", (value) => run(() => revokeLogin(str(value)), true))
}
