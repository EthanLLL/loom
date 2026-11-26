---
name: profiles
description: Add, change or remove a Claude Code or Codex profile — another model provider (an API key with a base URL, an Anthropic key, an OpenAI-compatible relay, a different Bedrock setup) that a new Loom session can be started on. Use when the user wants a session to use a different key, endpoint, relay or provider ("加个 profile", "用这个 key", "base url", "中转", "API key", "换个模型供应商").
---

# profiles: which provider a session talks to

A profile is a file in `~/.loom/profiles/<backend>/`: `claude_code/<name>.json`
for Claude Code, `codex/<name>.json` for Codex. Every file shows up in New chat
(web and the iOS app) as "Claude Code · <name>" or "Codex · <name>". The choice
is fixed for the session.

- `<name>`: letters, digits, `-`, `_`, `.`; at most 64 characters.
- The file holds a key: create it with mode 0600, and never print the key back.
- Removing a file breaks the sessions on it: their turns fail with
  "profile <name> not found". Check `grep -lE '"(cc|codex)_profile":"<name>"'
  ~/.loom/sessions/*/meta.json` first and tell the user which ones.

# Claude Code: `~/.loom/profiles/claude_code/<name>.json`

A Claude Code settings file. A session started on it passes the file to the
CLI as `--settings`, so its `env` overrides the machine's
`~/.claude/settings.json`.

- Loom reads the file at each spawn. An edit applies to a running session the
  next time its process starts (after an idle release, or `/reload`).
- The composer's model menu (Opus / Sonnet / Haiku) picks between
  `ANTHROPIC_DEFAULT_OPUS_MODEL`, `_SONNET_` and `_HAIKU_`. Set all three to
  names the endpoint knows. One left out falls back to the machine's id for
  that alias, which another provider will refuse.

### An endpoint with a key (Anthropic-compatible: relays, LiteLLM, Anthropic API)

```json
{
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "0",
    "ANTHROPIC_BASE_URL": "https://example.com",
    "ANTHROPIC_AUTH_TOKEN": "sk-…",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "<model name the endpoint expects>",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "<…>",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "<…>"
  }
}
```

- `ANTHROPIC_AUTH_TOKEN` is sent as `Authorization: Bearer`; an endpoint that
  wants `x-api-key` takes `ANTHROPIC_API_KEY` instead.
- The base URL is without `/v1`: CC appends `/v1/messages`.
- Set all three model names: the machine's defaults are Bedrock ids, which
  another endpoint will not know. Ask the user for the names if the provider's
  docs do not say.
- Set `"CLAUDE_CODE_USE_BEDROCK": "0"` even if this machine does not use
  Bedrock today; it costs nothing.

### Bedrock API keys (`bedrock-api-key-…`)

Bedrock's Anthropic-compatible endpoint takes them as a bearer token, with two
more lines than above (measured, CC 2.1.300):

```json
{
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "0",
    "ANTHROPIC_BASE_URL": "https://bedrock-runtime.<region>.amazonaws.com/anthropic",
    "ANTHROPIC_AUTH_TOKEN": "bedrock-api-key-…",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "us.anthropic.claude-opus-5-5",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "us.anthropic.claude-sonnet-5-5",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "us.anthropic.claude-haiku-5-5",
    "CLAUDE_CODE_EXTRA_BODY": "{\"metadata\":{\"user_id\":\"loom\"}}",
    "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
  }
}
```

- Model ids are inference-profile ids (`us.`/`eu.`/`global.` prefix). A bare
  `anthropic.…` id is refused for on-demand use, `claude-opus-5-5` is invalid;
  no `[1m]` suffix (the window is 1M anyway).
- Without `CLAUDE_CODE_EXTRA_BODY`: "400 Request metadata contains a value that
  violates the regular expression". CC sends `metadata.user_id` as a JSON
  string; the extra body replaces it.
- Without `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`: "400 Unexpected value(s)
  … for the `anthropic-beta` header".

Other relays can fail the same two ways; the same two lines fix them.

### Check it before handing it over

Run one prompt through it; a wrong URL, key or model name shows up here
rather than in the user's first turn:

```sh
claude -p --setting-sources user --settings ~/.loom/profiles/claude_code/<name>.json 'Reply with OK.'
```

# Codex: `~/.loom/profiles/codex/<name>.json`

An OpenAI-compatible endpoint, sent with every thread start and resume:

```json
{
  "base_url": "https://example.com/v1",
  "api_key": "sk-…",
  "models": ["<default model>", "<another>"]
}
```

- `base_url` includes `/v1`: Codex appends `/responses`. The key goes out as
  `Authorization: Bearer`. Optional `http_headers` (an object) is sent too.
- The endpoint must serve the **Responses API** (`POST /v1/responses`,
  streaming). One with only `/v1/chat/completions` cannot work: Codex refuses
  the chat wire format. Check this first.
- `models` is the composer's model menu for these sessions, the first the
  default. Loom never asks the endpoint, so pick them when making the file:
  list `GET <base_url>/models`, offer the user the plausible ones (a relay's
  list mixes in image, embedding and dated models), and test each pick with
  one streaming Responses call. A model can be listed yet refused (a 429
  "rate-limited", a 502); leave those out.
- Loom reads the file at each thread start and resume. An edit applies to a
  running session after `/reload` or the next Loom restart.

### Check it before handing it over

Without printing the key, for each model:

```sh
python3 - <<'PY'
import json, httpx
p = json.load(open("/home/ubuntu/.loom/profiles/codex/<name>.json"))
for m in p["models"]:
    with httpx.stream("POST", p["base_url"] + "/responses", timeout=60,
                      headers={"Authorization": "Bearer " + p["api_key"]},
                      json={"model": m, "input": "Reply with just: ok", "stream": True}) as r:
        text = "".join(json.loads(l[5:]).get("delta", "") for l in r.iter_lines()
                       if l.startswith("data:") and "output_text.delta" in l)
        print(m, r.status_code, repr(text))
PY
```

Each should print `200 'ok'`.
