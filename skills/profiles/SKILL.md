---
name: profiles
description: Add, change or remove a Claude Code profile — another model provider (an API key with a base URL, an Anthropic key, a different Bedrock setup) that a new Loom session can be started on. Use when the user wants a session to use a different key, endpoint, relay or provider ("加个 profile", "用这个 key", "base url", "中转", "API key", "换个模型供应商").
---

# profiles: which provider a Claude Code session talks to

A profile is a Claude Code settings file at `~/.loom/profiles/<name>.json`.
Every file there shows up in New chat as "Claude Code · <name>"; a session
started on it passes the file to the CLI as `--settings`, so its `env` overrides
the machine's `~/.claude/settings.json`. The choice is fixed for the session.

- `<name>`: letters, digits, `-`, `_`, `.`; at most 64 characters.
- The file holds a key: create it with mode 0600, and never print the key back.
- Loom reads the file at each spawn. An edit applies to a running session the
  next time its process starts (after an idle release, or `/reload`).
- Removing a file breaks the sessions on it: their turns fail with
  "profile <name> not found". Check `grep -l '"cc_profile":"<name>"'
  ~/.loom/sessions/*/meta.json` first and tell the user which ones.
- Sessions on a profile have no fallback model.

## An endpoint with a key (Anthropic-compatible: relays, LiteLLM, Anthropic API)

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

## Bedrock API keys (`bedrock-api-key-…`)

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

## Check it before handing it over

Run one prompt through it; a wrong URL, key or model name shows up here
rather than in the user's first turn:

```sh
claude -p --setting-sources user --settings ~/.loom/profiles/<name>.json 'Reply with OK.'
```
