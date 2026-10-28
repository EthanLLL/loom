import { useSyncExternalStore } from "react"

/**
 * Light or dark, per device. "system" follows the OS (and changes with it, as
 * a phone does at dusk); the other two pin it. The choice is put on <html> as
 * `data-theme`, where App.css swaps its variables, and in the browser's
 * theme-color so the status bar matches.
 */
export type ThemePref = "system" | "light" | "dark"
export type Theme = "light" | "dark"

const KEY = "loom_theme"
const dark = window.matchMedia("(prefers-color-scheme: dark)")
const listeners = new Set<() => void>()

function pref(): ThemePref {
  const v = localStorage.getItem(KEY)
  return v === "light" || v === "dark" ? v : "system"
}

function resolve(p: ThemePref): Theme {
  return p === "system" ? (dark.matches ? "dark" : "light") : p
}

function apply() {
  const theme = resolve(pref())
  document.documentElement.dataset.theme = theme
  const bg = getComputedStyle(document.documentElement).getPropertyValue("--bg").trim()
  document.querySelector('meta[name="theme-color"]')?.setAttribute("content", bg)
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
