import type { KeyboardEvent } from "react"

// True while an IME is composing, i.e. Enter/Escape belong to the IME (commit
// or cancel the candidate) and must not also submit or cancel the edit.
// Chrome sets isComposing on the committing keydown; Safari fires
// compositionend first, so isComposing is already false there, but the
// keydown still carries keyCode 229.
export function isComposing(e: KeyboardEvent): boolean {
  return e.nativeEvent.isComposing || e.keyCode === 229
}
