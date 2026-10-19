---
name: slides
description: Make a slide deck, presentation or talk as a reveal.js web page shown in Loom's canvas. Use when the user asks for slides, a deck, a presentation, a PPT, "幻灯片", "做个 slide", "演示文稿", "做个 PPT" — and there is no existing .pptx/.key file to edit (editing one of those is a different job).
---

# slides: a reveal.js deck in the canvas

A deck is one self-contained page, `<output dir>/<deck-name>/index.html`, which
opens in the canvas. The user presents from there: the canvas has a full-window
button that hides the chat and sidebar.

reveal.js and KaTeX are served by Loom itself under `/vendor/`, so a deck works
whenever Loom does. **Load them only from there — never from a CDN** — and pull
in nothing else from the network (no Google Fonts, no remote images): the deck
must open on a bad connection.

## Start from this

```html
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Deck title</title>
<link rel="stylesheet" href="/vendor/reveal.js/reset.css">
<link rel="stylesheet" href="/vendor/reveal.js/reveal.css">
<link rel="stylesheet" href="/vendor/reveal.js/theme/white.css">
<link rel="stylesheet" href="/vendor/reveal.js/plugin/highlight/monokai.css">
<style>
  /* The themes' fonts have no CJK glyphs; fall back to the system's. */
  .reveal { font-family: "Source Sans Pro", -apple-system, "PingFang SC",
    "Hiragino Sans GB", "Microsoft YaHei", "Noto Sans CJK SC", sans-serif; }
  .reveal h1, .reveal h2, .reveal h3 { font-family: inherit; text-transform: none; }
</style>
</head>
<body>
<div class="reveal"><div class="slides">

  <section>
    <h1>Title</h1>
    <p>Subtitle</p>
  </section>

  <section>
    <h2>One idea per slide</h2>
    <ul>
      <li class="fragment">Points appear one at a time</li>
      <li class="fragment">Inline math $e^{i\pi} + 1 = 0$</li>
    </ul>
    <aside class="notes">Speaker notes go here.</aside>
  </section>

  <section>
    <h2>Code</h2>
    <pre><code class="language-elixir" data-trim data-line-numbers>
Process.send_after(self(), :tick, 1_000)
    </code></pre>
  </section>

</div></div>

<script src="/vendor/reveal.js/reveal.js"></script>
<script src="/vendor/reveal.js/plugin/highlight.js"></script>
<script src="/vendor/reveal.js/plugin/math.js"></script>
<script src="/vendor/reveal.js/plugin/zoom.js"></script>
<script>
  Reveal.initialize({
    width: 1280,
    height: 720,
    hash: true,
    slideNumber: "c/t",
    katex: { local: "/vendor/katex" },
    plugins: [RevealHighlight, RevealMath.KaTeX, RevealZoom],
  })
</script>
</body>
</html>
```

## Rules

- **Themes**: only `white`, `black`, `serif`, `dracula`, `white-contrast`,
  `black-contrast`. The others import Google Fonts and break offline.
- **Plugins**: `highlight`, `math` (KaTeX, always with
  `katex: { local: "/vendor/katex" }`), `zoom`, `search`, `markdown`. Not
  `notes`: the canvas is sandboxed, so the speaker-notes window comes up blank.
  `<aside class="notes">` is still fine to write — it is just not shown.
- **Images and other assets** go beside `index.html` and are referenced
  relatively (`img/arch.png`), never by absolute path or URL.
- **Charts**: draw them as inline SVG or plain HTML/CSS. There is no charting
  library under `/vendor/`. Give each slide's `<svg>` its own `<defs>` (arrow
  markers, gradients) with ids unique in the page: reveal hides the other
  slides, and a `url(#id)` pointing into a hidden one renders nothing.
- **Content**: one idea per slide, at most about six short bullets, no
  paragraphs. Use `class="fragment"` to build a slide up step by step, and
  nested `<section>`s (vertical slides) only for optional detail.
- **Fit**: everything must fit in 1280×720 without scrolling. Split a slide
  rather than shrink its text.

## Revising

Edit the same `index.html` in place; the canvas shows the newest version.
`hash: true` keeps the URL on the current slide, so after the canvas reloads
the user stays where they were.

## Exporting

If the user wants a PDF: they can open the deck in a browser tab with
`?print-pdf` appended to the URL and print to PDF. If they want a real .pptx,
say that this deck is a web page and a .pptx is a separate job.
