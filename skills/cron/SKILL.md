---
name: cron
description: Schedule, list or delete Loom's timed prompts — a fixed message submitted to a session at cron times, like the user typing it. Use when the user wants something done on a schedule or reminded later ("每天早上", "每周一", "定时", "提醒我", "every morning", "cron", "定时任务"), or asks what is scheduled.
---

# cron: scheduled prompts in Loom

At each match of a cron expression, Loom submits a fixed prompt to an existing
session. The reply lands in that session like any other turn, marked ⏰ cron.
Jobs live in `~/.loom/cron.json`; never edit it — go through `Loom.Cron` over
`bin/loom rpc`, which needs no running session of yours and no HTTP.

## Calling it

```sh
B="$(dirname "$LOOM_ENV_FILE")/_build/prod/rel/loom/bin/loom"
$B rpc "$(cat <<'EOF'
IO.inspect(Loom.Cron.add(%{name: "Morning news", cron: "0 1 * * *", target: "a_xxx", prompt: ~S"""
The prompt, verbatim: quotes, What's, newlines and #{} all stay as written.
"""}))
EOF
)"
$B rpc 'IO.inspect(Loom.Cron.list())'
$B rpc 'IO.inspect(Loom.Cron.delete("c_xxx"))'
```

- Wrap every call in `IO.inspect`: rpc prints nothing otherwise.
- The quoted heredoc plus `~S"""` keeps the prompt literal; it only must not
  contain `"""`.
- `add` returns `{:ok, job}` with `next_at` (first fire, UTC), or
  `{:error, reason}`.

## Fields

- `cron`: five fields (minute hour day month weekday), **always UTC**. `*`,
  `a,b`, `a-b`, `*/n`, `a-b/n`, and names like `MON`, `JAN`. No `@daily`, no
  seconds. With both day and weekday set, either one matching fires.
- `target`: the id of an existing session. Find it by title:
  `$B rpc 'IO.inspect(Loom.Agent.list_persisted() |> Enum.map(&{&1[:id], &1[:title]}))'`.
  If it is unclear which session ("this one", "here"), confirm the title
  with the user.
- `name`: optional; defaults to the prompt's first line.
- `prompt`: what the target sees when it fires, with none of this
  conversation around it — write it to stand on its own.

## Time zones

The user speaks local time; cron is UTC. Convert it yourself (Beijing = UTC+8,
no DST: 9:00 there is `0 1 * * *`, and a weekday can shift across midnight). If
the zone is unclear, ask. After adding, tell the user the next fire time back
in their own zone so they can check it.

## Behaviour

- A fire missed while Loom was down is skipped, not caught up.
- A busy target gets the prompt like a typed message: steered into the running
  turn, or queued.
- Deleting the target session leaves the job; it records `last_error` until
  deleted.
- `/cron` typed in any session lists every job.
