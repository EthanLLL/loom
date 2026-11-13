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
 * Safari's scroll to the focused field can land after the resize that told us
 * the keyboard is up, and sometimes comes again later, which would leave the
 * shrunken app above the visible part with the composer at its top edge. So
 * every scroll is undone too, for as long as the keyboard stays.
 *
 * Chrome on Android already resizes the layout (see index.html), so there the
 * two heights agree and none of this engages.
 *
 * Installed to the Home Screen, WebKit has a bug of its own: back from the
 * background, the window itself can come back shorter (82px on the Duo's
 * inner screen, in landscape), a black band where the rest was. Measured with
 * the readout (ViewportReadout.tsx): `innerHeight` drops with it, so it is the
 * window and not the page — `100dvh` follows it and keeps the composer in
 * sight, where `100vh` left it below the edge. What the page can do is undo
 * any scroll it was left with, and, if the window stays short, set the
 * viewport again, which makes WebKit measure it again.
 */
export function fitToKeyboard(): void {
  const vv = window.visualViewport
  if (!vv) return
  const root = document.documentElement
  const standalone =
    (navigator as Navigator & { standalone?: boolean }).standalone === true ||
    matchMedia("(display-mode: standalone)").matches
  root.classList.toggle("standalone", standalone)

  // Scrolled at all, either way: the page never scrolls itself, only Safari
  // does, to a focused field or to "dock" a page it measured wrong.
  const shifted = () => window.scrollX !== 0 || window.scrollY !== 0 || vv.offsetTop !== 0 || vv.offsetLeft !== 0

  const update = () => {
    // Anything this much shorter than the layout is a keyboard, not the
    // toolbar collapsing — while something takes typing, which is the only
    // time there is one. Unfolding the Duo has WebKit report a visual
    // viewport 0px tall for a while; taken for a keyboard, that sized the app
    // to nothing and left the screen black.
    const field = document.activeElement
    const typing =
      field instanceof HTMLTextAreaElement ||
      (field instanceof HTMLInputElement && !["button", "checkbox", "radio", "range", "file"].includes(field.type)) ||
      (field instanceof HTMLElement && field.isContentEditable)
    const keyboard = typing && vv.height > 100 && window.innerHeight - vv.height > 120
    root.classList.toggle("keyboard", keyboard)

    if (keyboard) {
      root.style.setProperty("--app-height", `${vv.height}px`)
      // The app now fits the visible part exactly; undo Safari's scroll so
      // that part is the top of the page.
      if (shifted()) window.scrollTo(0, 0)
    } else {
      root.style.removeProperty("--app-height")
      if (shifted()) window.scrollTo(0, 0)
    }
  }

  // The tallest the window has been, per orientation, with no keyboard up.
  const tallest = new Map<string, number>()
  const orientation = () => (innerWidth > innerHeight ? "landscape" : "portrait")
  const meta = document.querySelector<HTMLMetaElement>('meta[name="viewport"]')
  // Once per return, not on every resize: setting it can resize the window,
  // which would set it again.
  const remeasure = (kick: boolean) => {
    if (root.classList.contains("keyboard")) return
    const was = tallest.get(orientation()) ?? 0
    if (innerHeight > was) tallest.set(orientation(), innerHeight)
    else if (kick && was - innerHeight > 40 && meta) {
      const content = meta.content
      meta.content = content + ", minimum-scale=1.0"
      requestAnimationFrame(() => (meta.content = content))
    }
  }

  // Back from the background or turned: WebKit measures again a moment
  // later, sometimes more than once, so look again after it has.
  const settle = () => {
    update()
    for (const ms of [100, 400, 1000]) setTimeout(update, ms)
    setTimeout(() => remeasure(true), 1200)
  }
  document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && settle())
  window.addEventListener("pageshow", settle)
  window.addEventListener("orientationchange", settle)

  vv.addEventListener("resize", update)
  window.addEventListener("resize", () => remeasure(false))
  vv.addEventListener("scroll", update)
  // Leaving a field ends the keyboard even if no resize says so.
  document.addEventListener("focusout", () => setTimeout(update, 0))
  window.addEventListener("scroll", update)
  update()
  remeasure(false)
}
