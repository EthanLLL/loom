/**
 * Fit the app to what is visible above an on-screen keyboard.
 *
 * iOS Safari does not resize the page for the keyboard (and ignores
 * `interactive-widget`): it keeps the full height and scrolls until the
 * focused field shows. Where that leaves the composer depends on how tall the
 * field is — one line left the bottom safe-area padding showing as a gap above
 * the keyboard, a taller box pushed it out of sight. So while the keyboard is
 * up the app is sized to the visual viewport instead, pinned to the top, and
 * the padding for the home indicator (which the keyboard covers) goes.
 *
 * Chrome on Android already resizes the layout (see index.html), so there the
 * two heights agree and none of this engages.
 */
export function fitToKeyboard(): void {
  const vv = window.visualViewport
  if (!vv) return
  const root = document.documentElement

  const update = () => {
    // Anything this much shorter than the layout is a keyboard, not the
    // toolbar collapsing.
    const keyboard = window.innerHeight - vv.height > 120
    root.classList.toggle("keyboard", keyboard)

    if (keyboard) {
      root.style.setProperty("--app-height", `${vv.height}px`)
      // The app now fits the visible part exactly; undo Safari's scroll so
      // that part is the top of the page.
      window.scrollTo(0, 0)
    } else {
      root.style.removeProperty("--app-height")
    }
  }

  vv.addEventListener("resize", update)
  update()
}
