#!/usr/bin/env node
/**
 * Copy the libraries agent-written pages may load into `dist/vendor/`, which
 * Phoenix serves at `/vendor/` (see `LoomWeb.Endpoint`).
 *
 * A slide deck in the canvas should open whenever loom does, so it loads
 * reveal.js and KaTeX from loom itself rather than from a CDN. The paths are
 * unversioned on purpose: a deck written today keeps working after an
 * upgrade, which a `reveal.js@6.0.2/` path would not.
 *
 *   /vendor/reveal.js/   reveal.js's `dist/` (core, plugins, themes)
 *   /vendor/katex/dist/  KaTeX's `dist/` — the layout the math plugin's
 *                        `katex: { local: "/vendor/katex" }` expects
 *
 * Runs after `vite build`, from `pnpm build`.
 */
import { cpSync, rmSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const out = join(root, "dist", "vendor")
const pkg = (name) => join(root, "node_modules", name)
// Type declarations are for bundlers; nothing loads them over HTTP.
const filter = (src) => !src.endsWith(".d.ts")

rmSync(out, { recursive: true, force: true })
cpSync(join(pkg("reveal.js"), "dist"), join(out, "reveal.js"), { recursive: true, filter })
cpSync(join(pkg("katex"), "dist"), join(out, "katex", "dist"), { recursive: true, filter })
