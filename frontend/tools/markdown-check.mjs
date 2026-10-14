#!/usr/bin/env node
/**
 * Render a set of awkward markdown inputs through the real `Markdown`
 * component and assert what came out.
 *
 * There is no test runner in this project, and adding one to guard a single
 * component would cost more than it is worth — but one property here does
 * deserve a guard that fails loudly: **model output must never reach the DOM as
 * markup.** The agent fetches web pages and quotes them, so a page's
 * `<script>` or `javascript:` href travels through the model and into this
 * renderer. `markdown.tsx` makes that structurally impossible by rendering
 * tokens rather than HTML; these cases prove it stays that way.
 *
 * The rest are the shapes models actually emit — tables above all — plus the
 * half-finished input that is normal mid-stream.
 *
 *   node tools/markdown-check.mjs
 *
 * `markdown.tsx` is JSX, which Node strips types from but does not transform,
 * so it is compiled to a temp directory first with the project's own tsc.
 */

import { execFileSync } from "node:child_process"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ROOT = path.resolve(HERE, "..")
// Inside node_modules, not /tmp: the compiled module imports `react` and
// `marked`, and Node resolves those by walking up from the file itself.
const OUT = path.join(ROOT, "node_modules/.cache/loom-markdown-check")
fs.mkdirSync(OUT, { recursive: true })

execFileSync(
  process.execPath,
  [
    path.join(ROOT, "node_modules/typescript/bin/tsc"),
    path.join(ROOT, "src/markdown.tsx"),
    "--ignoreConfig",
    "--outDir",
    OUT,
    "--jsx",
    "react-jsx",
    "--module",
    "esnext",
    "--target",
    "es2022",
    "--moduleResolution",
    "bundler",
    "--skipLibCheck",
  ],
  { stdio: "inherit", cwd: ROOT },
)

const { Markdown } = await import(path.join(OUT, "markdown.js"))
const { renderToStaticMarkup } = await import("react-dom/server")
const { createElement } = await import("react")

const render = (text) => renderToStaticMarkup(createElement(Markdown, { text }))

const cases = [
  {
    name: "a GFM table becomes a real table",
    md: "| a | b |\n|---|---:|\n| 1 | 2 |",
    want: ["<table", "<th", "<td", 'style="text-align:right"'],
  },
  {
    name: "html in model output is text, not markup",
    md: "before <script>alert(1)</script> after",
    want: ["&lt;script&gt;"],
    reject: ["<script>"],
  },
  {
    name: "an img tag is text too",
    md: `<img src=x onerror="alert(1)">`,
    want: ["&lt;img"],
    reject: ["<img", "onerror=\""],
  },
  {
    name: "a javascript: link is shown but not clickable",
    md: "[click](javascript:alert(1))",
    want: ["md-link-blocked", "click"],
    reject: ["href=\"javascript"],
  },
  {
    name: "an http link opens safely",
    md: "[docs](https://example.com/a)",
    want: ['href="https://example.com/a"', 'rel="noopener noreferrer"', 'target="_blank"'],
  },
  {
    name: "a markdown image is named, never loaded",
    md: "![alt](https://evil.test/track.gif)",
    want: ["md-image"],
    reject: ["<img"],
  },
  {
    name: "an unterminated fence still renders as code",
    md: "text\n\n```py\nprint(1",
    want: ["<pre", "print(1", "code-lang"],
  },
  {
    name: "inline code keeps its angle brackets",
    md: "use `a < b && c > d`",
    want: ["<code>", "a &lt; b &amp;&amp; c &gt; d"],
  },
  {
    name: "headings are capped at h3",
    md: "# one\n\n#### four",
    want: ["<h1", "<h3"],
    reject: ["<h4"],
  },
  {
    name: "task lists render their state",
    md: "- [x] done\n- [ ] todo",
    want: ["md-task", "md-check"],
  },
  {
    name: "emphasis, strike and quotes",
    md: "**b** *i* ~~s~~\n\n> quoted",
    want: ["<strong>", "<em>", "<del>", "md-quote"],
  },
  {
    name: "a half-written table reads as text until its delimiter row",
    md: "| a | b",
    want: ["md-p"],
    reject: ["<table"],
  },
  {
    name: "empty input renders nothing but the wrapper",
    md: "",
    want: ['class="md"'],
  },
]

let failed = 0

for (const c of cases) {
  const html = render(c.md)
  const missing = (c.want ?? []).filter((w) => !html.includes(w))
  const present = (c.reject ?? []).filter((w) => html.includes(w))

  if (missing.length === 0 && present.length === 0) {
    console.log(`  ok    ${c.name}`)
    continue
  }

  failed++
  console.log(`  FAIL  ${c.name}`)
  for (const m of missing) console.log(`          expected to contain ${JSON.stringify(m)}`)
  for (const p of present) console.log(`          expected NOT to contain ${JSON.stringify(p)}`)
  console.log(`          got: ${html.slice(0, 300)}`)
}

fs.rmSync(OUT, { recursive: true, force: true })

console.log(
  failed === 0
    ? `\n${cases.length} cases passed`
    : `\n${failed} of ${cases.length} cases failed`,
)
process.exit(failed === 0 ? 0 : 1)
