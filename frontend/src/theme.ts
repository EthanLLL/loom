import { useSyncExternalStore } from "react"
import { tellNativeTheme } from "./native"

/**
 * Light or dark, per device. "system" follows the OS (and changes with it, as
 * a phone does at dusk); the others pin it — Cool Night is a second dark. The choice is put on <html> as
 * `data-theme`, where App.css swaps its variables, and in the browser's
 * theme-color so the status bar matches.
 */
export type Theme = "light" | "dark" | "coolnight"
export type ThemePref = "system" | Theme

const KEY = "loom_theme"
const dark = window.matchMedia("(prefers-color-scheme: dark)")
const listeners = new Set<() => void>()

function pref(): ThemePref {
  const v = localStorage.getItem(KEY)
  return v === "light" || v === "dark" || v === "coolnight" ? v : "system"
}

function resolve(p: ThemePref): Theme {
  return p === "system" ? (dark.matches ? "dark" : "light") : p
}

// Any CSS colour as #rrggbb, by painting one pixel with it.
function hex(color: string): string {
  const ctx = document.createElement("canvas").getContext("2d")
  if (!ctx) return color
  ctx.fillStyle = color
  ctx.fillRect(0, 0, 1, 1)
  const [r, g, b] = ctx.getImageData(0, 0, 1, 1).data
  return "#" + [r, g, b].map((n) => n.toString(16).padStart(2, "0")).join("")
}

function apply() {
  const theme = resolve(pref())
  document.documentElement.dataset.theme = theme
  // The backdrop the cards sit on (`bg-sidebar`), as #rrggbb: the variable
  // is oklch(), which neither theme-color nor the iOS app reads.
  const bg = hex(getComputedStyle(document.documentElement).getPropertyValue("--sidebar").trim())
  document.querySelector('meta[name="theme-color"]')?.setAttribute("content", bg)
  tellNativeTheme(bg, theme !== "light")
  listeners.forEach((f) => f())
}

export function setThemePref(p: ThemePref) {
  if (p === "system") localStorage.removeItem(KEY)
  else localStorage.setItem(KEY, p)
  apply()
}

function subscribe(f: () => void) {
  listeners.add(f)
  return () => listeners.delete(f)
}

dark.addEventListener("change", apply)
apply()

export function useThemePref(): ThemePref {
  return useSyncExternalStore(subscribe, pref)
}

export function useTheme(): Theme {
  return useSyncExternalStore(subscribe, () => resolve(pref()))
}
