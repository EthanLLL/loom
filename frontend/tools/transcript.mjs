#!/usr/bin/env node
/**
 * Record a live agent session's wire stream, then replay it through the real
 * client reducers and report what the UI would have rendered.
 *
 * Every rendering bug so far has been one of two things, and they look
 * identical in the browser:
 *
 *   - the data is wrong   — duplicated deltas, colliding block ids, events
 *                           whose block_id does not match their deltas
 *   - the data is fine    — and it is CSS
 *
 * Guessing which costs an hour. This answers it in one run: it imports
 * `src/agent.ts` unchanged, so the timeline it prints is exactly the timeline
 * `Chat.tsx` receives. If the dump looks right, stop reading TypeScript and go
 * look at the stylesheet.
 *
 *   node tools/transcript.mjs record <session-id> ["a prompt"] [--attach <file>]
 *   node tools/transcript.mjs replay <file.json> [--steps]
 *   node tools/transcript.mjs check  <file.json>
 *
 * `record` writes `tools/recordings/<session>-<time>.json` — the raw frames in
 * arrival order, which is the part you cannot reconstruct afterwards.
 *
 * Env: LOOM_URL (default http://localhost:4000), LOOM_PASSWORD (default loom).
 *
 * Node 24 strips the types off `../src/agent.ts` on import, so there is no
 * build step and no second copy of the reducer to drift out of sync.
 */

import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { Socket } from "phoenix"
import { applySnapshot, applyEvent, applyDelta, buildTimeline } from "../src/agent.ts"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const BASE = (process.env.LOOM_URL ?? "http://localhost:4000").replace(/\/$/, "")
const PASSWORD = process.env.LOOM_PASSWORD ?? "loom"

// ── Recording ──────────────────────────────────────────────────────────────

async function login() {
  const res = await fetch(`${BASE}/api/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ password: PASSWORD }),
  })
  if (!res.ok) throw new Error(`login failed: ${res.status} — is the server up at ${BASE}?`)
  return (await res.json()).token
}

/** Upload local files as this session's attachments, as the browser does. */
async function upload(token, sessionId, paths) {
  const body = new FormData()
  for (const p of paths) {
    body.append("files[]", new Blob([fs.readFileSync(p)]), path.basename(p))
  }

  const res = await fetch(`${BASE}/api/agents/${sessionId}/files`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}` },
    body,
  })
  if (!res.ok) throw new Error(`upload failed: ${res.status} ${await res.text()}`)
  return (await res.json()).files
}

async function record(sessionId, prompt, attach = []) {
  if (!sessionId) die("record needs a session id (see the sidebar, or GET /api/agents)")

  const token = await login()
  const files = attach.length > 0 ? await upload(token, sessionId, attach) : []
  if (files.length > 0) console.error(`attached: ${files.map((f) => f.path).join(", ")}`)
  const socket = new Socket(`${BASE.replace(/^http/, "ws")}/socket`, {
    params: { token },
    transport: WebSocket,
  })
  socket.connect()

  // Arrival order is the whole point: it is what reveals a duplicate, a
  // late delta, or an event that lands before the deltas it supersedes.
  const frames = []
  const at = () => Date.now() - started
  const started = Date.now()

  const channel = socket.channel(`agent:${sessionId}`, () => ({
    since_seq: 0,
    device: "transcript-tool",
  }))
  channel.on("event", (event) => frames.push({ at: at(), kind: "event", event }))
  channel.on("delta", (delta) => frames.push({ at: at(), kind: "delta", delta }))

  const snapshot = await new Promise((resolve, reject) => {
    channel
      .join()
      .receive("ok", resolve)
      .receive("error", (r) => reject(new Error(`join refused: ${JSON.stringify(r)}`)))
      .receive("timeout", () => reject(new Error("join timed out")))
  })

  if (prompt || files.length > 0) {
    channel.push("submit", {
      text: prompt ?? "",
      client_msg_id: "transcript-tool",
      files,
    })
    console.error(`submitted: ${prompt}`)
  }

  console.error("recording — the turn ends it, or ctrl-c")
  await turnEnd(frames)

  const file = path.join(
    HERE,
    "recordings",
    `${sessionId}-${new Date().toISOString().replace(/[:.]/g, "-")}.json`,
  )
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, JSON.stringify({ sessionId, snapshot, frames }, null, 2))
  console.error(`\n${frames.length} frames → ${path.relative(process.cwd(), file)}`)
  report(replay({ snapshot, frames }))
  process.exit(0)
}

// Stop when the session goes quiet after a turn rather than on a fixed timer:
// a turn with several tool rounds can take minutes.
function turnEnd(frames) {
  return new Promise((resolve) => {
    let seen = frames.length
    const tick = setInterval(() => {
      const done = frames.some(
        (f) =>
          f.kind === "event" &&
          (f.event.kind === "turn_done" || f.event.kind === "turn_failed"),
      )
      if (done && frames.length === seen) {
        clearInterval(tick)
        resolve()
      }
      seen = frames.length
    }, 1500)
    process.on("SIGINT", () => {
      clearInterval(tick)
      resolve()
    })
  })
}

// ── Replay ─────────────────────────────────────────────────────────────────

/** Fold a recording through the real reducers, keeping every intermediate. */
function replay({ snapshot, frames }) {
  let t = applySnapshot(snapshot, undefined)
  const steps = [{ frame: null, transcript: t }]

  for (const frame of frames) {
    t = frame.kind === "event" ? applyEvent(t, frame.event) : applyDelta(t, frame.delta)
    steps.push({ frame, transcript: t })
  }

  return { steps, final: t, frames }
}

function describe(item) {
  switch (item.kind) {
    case "tool":
      return `${item.name} ${item.result ? (item.result.ok ? "ok" : "ERROR") : "pending"}`
    case "turn":
      return `ctx=${item.contextTokens}${item.contextWindow ? `/${item.contextWindow}` : ""}`
    default:
      return JSON.stringify((item.text ?? "").slice(0, 46))
  }
}

/** Items the browser would paint as nothing at all. */
function blank(item) {
  if (item.kind === "tool" || item.kind === "turn" || item.kind === "question") return false
  if (item.kind === "thinking") return false // has a fallback label
  // A message can be nothing but attachments: a dropped screenshot with no
  // words is a normal way to ask about it.
  if ((item.files?.length ?? 0) > 0) return false
  return (item.text ?? "").trim() === ""
}

function printTimeline(t, label) {
  const items = buildTimeline(t)
  console.log(
    `\n── ${label} — ${items.length} items, ${t.streaming.length} streaming, ` +
      `${t.toolStreams.length} tool streams`,
  )
  for (const [i, item] of items.entries()) {
    const flags = [item.streaming ? "LIVE" : "", blank(item) ? "BLANK" : ""]
      .filter(Boolean)
      .join(" ")
    console.log(
      `  ${String(i).padStart(2)} ${item.kind.padEnd(10)} ${flags.padEnd(10)} ` +
        `${item.key.slice(0, 28).padEnd(28)} ${describe(item)}`,
    )
  }
}

// ── Anomalies ──────────────────────────────────────────────────────────────

function anomalies({ final, frames }) {
  const found = []

  const items = buildTimeline(final)
  for (const item of items) {
    if (blank(item)) found.push(`renders as nothing: ${item.kind} ${item.key}`)
  }

  // A placeholder with no authoritative event behind it. Legitimate only
  // mid-turn; in a finished recording it is a leak.
  for (const block of final.streaming) {
    found.push(`streaming block never superseded: ${block.blockId} (${block.kind})`)
  }
  for (const stream of final.toolStreams) {
    found.push(`tool output never superseded: ${stream.blockId}`)
  }

  // Double delivery. phoenix.js skips the leave push for a channel that has
  // not finished joining, so a mount-remount can leave two server channels
  // pushing to one socket.
  const seq = new Map()
  for (const f of frames) {
    if (f.kind !== "delta" || f.delta.delta_seq === undefined) continue
    seq.set(f.delta.delta_seq, (seq.get(f.delta.delta_seq) ?? 0) + 1)
  }
  const doubled = [...seq.values()].filter((n) => n > 1).length
  if (doubled > 0) {
    found.push(`${doubled} delta(s) delivered more than once — duplicate channel?`)
  }

  // One block id must belong to one block. Reusing it made the second answer
  // of a turn stream into the first one's placeholder.
  const owners = new Map()
  for (const f of frames) {
    if (f.kind !== "event") continue
    const id = f.event.payload?.block_id
    if (!id) continue
    if (owners.has(id) && owners.get(id) !== f.event.seq) {
      found.push(`block_id reused by events ${owners.get(id)} and ${f.event.seq}: ${id}`)
    }
    owners.set(id, f.event.seq)
  }

  for (const item of items) {
    if (item.kind === "tool" && !item.result) {
      found.push(`tool left pending: ${item.name}`)
    }
  }

  return found
}

function report(result) {
  printTimeline(result.final, "final")
  const found = anomalies(result)
  console.log("")
  if (found.length === 0) {
    console.log("no anomalies — the data is fine, so a rendering problem is in the CSS")
    return 0
  }
  for (const line of found) console.log(`ANOMALY  ${line}`)
  return 1
}

function load(file) {
  if (!file) die("needs a recording file")
  return JSON.parse(fs.readFileSync(file, "utf8"))
}

function die(message) {
  console.error(`transcript: ${message}`)
  process.exit(2)
}

// ── Entry ──────────────────────────────────────────────────────────────────

const [command, arg, ...rest] = process.argv.slice(2)

switch (command) {
  case "record": {
    // `--attach <path>` uploads the file first and submits it with the prompt,
    // which is the only way to reproduce an attachment bug from the shell.
    const attach = []
    const words = []
    for (let i = 0; i < rest.length; i++) {
      if (rest[i] === "--attach") attach.push(rest[++i])
      else if (!rest[i].startsWith("--")) words.push(rest[i])
    }
    await record(arg, words.join(" ") || null, attach)
    break
  }

  case "replay": {
    const result = replay(load(arg))
    if (rest.includes("--steps")) {
      // Every intermediate state, for the bugs that only exist mid-stream.
      for (const [i, step] of result.steps.entries()) {
        if (!step.frame) continue
        const what =
          step.frame.kind === "event"
            ? `event ${step.frame.event.kind}`
            : `delta ${step.frame.delta.type} ${step.frame.delta.block_id?.slice(-10)}`
        printTimeline(step.transcript, `step ${i} (+${step.frame.at}ms) ${what}`)
      }
    }
    process.exit(report(result))
  }

  case "check":
    process.exit(report(replay(load(arg))))

  default:
    console.error(
      [
        "usage:",
        "  node tools/transcript.mjs record <session-id> [prompt…] [--attach <file>]",
        "  node tools/transcript.mjs replay <file.json> [--steps]",
        "  node tools/transcript.mjs check  <file.json>",
      ].join("\n"),
    )
    process.exit(2)
}
