---
name: sessions
description: Run work in parallel as new Loom sessions the user can watch in the sidebar — start one per task, hand each a prompt, check on them and collect their answers. Use when the user asks for parallel work ("并行", "同时跑", "开几个会话", "分头", "in parallel", "spawn sessions"), instead of background agents or background shell tasks.
---

# sessions: parallel work as Loom sessions

Default to working in the foreground. When the user asks for parallel work, start
new Loom sessions rather than background agents: they show up in the sidebar,
the user can read and steer them, and they survive this process. A background
agent or shell task does not — Loom releases an idle backend 15 minutes after
its last turn, and anything it was waiting on is lost.

The exception is a short subagent job your instructions call for (CLAUDE.md /
AGENTS.md), such as transcribing a batch of images: it finishes within the
turn, so nothing is left waiting.

## Calling it

```sh
B="$(dirname "$LOOM_ENV_FILE")/_build/prod/rel/loom/bin/loom"
$B rpc "$(cat <<'EOF'
id = "a_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
{:ok, _} = Loom.Agent.start_session(id, backend: :claude_code, title: "Short title")
IO.inspect({id, Loom.Agent.submit(id, ~S"""
The task, written to stand on its own.
""")})
EOF
)"
$B rpc 'IO.inspect(Loom.Agent.info("a_xxx").status)'       # :running, :idle, :interrupted…
$B rpc '{:ok, %{events: ev}} = Loom.Agent.attach("a_xxx")
IO.puts(ev |> Enum.filter(&(&1.kind == :assistant_text)) |> List.last() |> then(& &1.payload.text))'   # last reply
```

- `backend:` is `:claude_code` or `:codex`, fixed for the session's life.
- The new session knows nothing of this conversation: put the goal, inputs,
  paths, constraints and what "done" means in the prompt, and say where to
  write results (a file both can read beats parsing replies).
- Tell the user the titles you started. Each new session costs a fresh context
  (~20k tokens before it does anything), so start as many as the work needs.
- To wait for them, don't poll in a loop: check once when the user asks, or
  schedule a check-in on this session with the `cron` skill.
- `Loom.Agent.delete_session(id)` discards one and its history; only when the
  user asks.
