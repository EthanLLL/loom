import { useSyncExternalStore } from "react"

// A phone. Same breakpoint as the font step in index.css. A foldable opened up
// is wider than this and keeps the three-column layout; see App.css.
const NARROW = "(max-width: 640px)"

/** Whether the viewport is phone-width. Follows rotation and resizes. */
export function useNarrow(): boolean {
  return useSyncExternalStore(subscribe, () => matchMedia(NARROW).matches)
}

function subscribe(onChange: () => void): () => void {
  const query = matchMedia(NARROW)
  query.addEventListener("change", onChange)
  return () => query.removeEventListener("change", onChange)
}

// Wider than a phone but short of room for the sidebar, the chat and the
// right-hand column side by side: the Duo's inner screen, a small laptop.
const COMPACT = "(min-width: 641px) and (max-width: 1279px)"

/** Whether the sidebar and the right-hand column should take turns. */
export function useCompact(): boolean {
  return useSyncExternalStore(
    (onChange) => {
      const query = matchMedia(COMPACT)
      query.addEventListener("change", onChange)
      return () => query.removeEventListener("change", onChange)
    },
    () => matchMedia(COMPACT).matches,
  )
}
