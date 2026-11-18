import { useEffect, useRef, useState } from "react"

/**
 * Vim-style keys for the desktop layout.
 *
 * There is no mode of its own: where the focus is decides. In anything that
 * takes text — the composer, a rename box, a shell — keys are typed as usual,
 * and Escape leaves the composer (only the composer: elsewhere Escape already
 * means "cancel" and a blur would commit instead). Anywhere else a key is
 * looked up here, with Space as the leader. A sequence is the keys' names
 * joined by spaces, e.g. "Space e" or "g g"; a prefix of one waits for the
 * next key, and `WhichKey` shows what can follow.
 *
 * Nothing reaches this from inside the canvas: it is a sandboxed iframe, and a
 * page there keeps its keys to itself.
 */
export type Binding = { desc: string; run: () => void }
export type Keymap = Record<string, Binding>

/** What a key is called in a sequence: `j`, `G`, `C-d`, `Space`, `Esc`. */
function keyName(e: KeyboardEvent): string | null {
  if (["Shift", "Control", "Alt", "Meta", "CapsLock"].includes(e.key)) return null
  const key = e.key === " " ? "Space" : e.key === "Escape" ? "Esc" : e.key
  return e.ctrlKey ? `C-${key.toLowerCase()}` : key
}

function takesText(el: Element | null): boolean {
  return !!el?.closest?.("input, textarea, select, [contenteditable=''], [contenteditable='true']")
}

/**
 * Runs `keymap` while `enabled`. Returns the keys typed so far of a sequence
 * still waiting for its end, empty when none is.
 */
export function useKeys(enabled: boolean, keymap: Keymap): string[] {
  const [pending, setPending] = useState<string[]>([])
  // The latest of each, without re-adding the listener every render.
  const map = useRef(keymap)
  map.current = keymap
  const typed = useRef<string[]>([])
  // Only when it changes: most keys start and end nothing, and a render for
  // each of them would be wasted.
  const set = (keys: string[]) => {
    if (keys.length === 0 && typed.current.length === 0) return
    typed.current = keys
    setPending(keys)
  }

  useEffect(() => {
    if (!enabled) {
      set([])
      return
    }
    const onKey = (e: KeyboardEvent) => {
      // Taken already: a command menu's Escape, a dialog's own keys.
      if (e.defaultPrevented || e.metaKey || e.altKey) return
      if (document.querySelector(".modal")) return
      const target = e.target as Element | null
      if (takesText(target)) {
        // An IME uses Escape to drop its candidate; that is not leaving.
        if (
          e.key === "Escape" &&
          !e.isComposing &&
          e.keyCode !== 229 &&
          target?.matches(".composer-input")
        ) {
          ;(target as HTMLElement).blur()
        }
        return
      }

      const name = keyName(e)
      if (name === null) return
      const before = typed.current
      const seq = [...before, name].join(" ")
      const binding = map.current[seq]
      const waits = Object.keys(map.current).some((k) => k.startsWith(seq + " "))

      if (binding || waits || before.length > 0) {
        e.preventDefault()
        // Space or Enter on a button still focused from a click would press it.
        if (target instanceof HTMLElement && target !== document.body) target.blur()
      }
      if (binding) {
        set([])
        binding.run()
      } else if (waits && name !== "Esc") {
        set([...before, name])
      } else {
        set([])
      }
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [enabled])

  return pending
}

/** A key that works wherever the focus is, a shell included. */
export function useGlobalKey(enabled: boolean, matches: (e: KeyboardEvent) => boolean, run: () => void) {
  const latest = useRef(run)
  latest.current = run
  useEffect(() => {
    if (!enabled) return
    // Capturing, so it is seen before xterm takes it for the shell.
    const onKey = (e: KeyboardEvent) => {
      if (!matches(e)) return
      e.preventDefault()
      e.stopPropagation()
      latest.current()
    }
    window.addEventListener("keydown", onKey, true)
    return () => window.removeEventListener("keydown", onKey, true)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled])
}
