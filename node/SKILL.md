---
name: loom-nodes
description: Run commands and read or write files on the user's own machines (their Mac, WSL, home PC) rather than on this server. Use when the user refers to "my computer", "my Mac", "local", "本地", "我电脑上", "我的 Mac", "WSL", or a device by name, or asks for something that only exists on their machine.
---

# loom-nodes: the user's own devices

This server is not the user's computer. Their machines connect to loom and can
be reached with the `loom-node` CLI, from your shell.

## 1. See what is there

```sh
loom-node list
```

Shows each device's name, whether it is online, its OS and arch. Use the
NAME column in the commands below. If the user did not say which device and
there is more than one online, ask.

## 2. Run a command

```sh
loom-node exec <device> [--cwd DIR] [--timeout SECONDS] -- '<command>'
```

- **Single-quote the command.** It is run on the device by the user's login
  shell (`$SHELL -lc`). Unquoted, `~`, `$VAR`, globs and pipes would be
  expanded by *this* server's shell first.
- Starts in the device's home directory unless `--cwd` is given.
- stdout and stderr come back as they are produced, and the exit code is the
  command's own.
- No stdin and no terminal: anything interactive (prompts, `sudo` asking for a
  password, editors, pagers) cannot be answered. Pass flags like `-y`, or use
  `git --no-pager`, `| cat`.
- Default timeout 120s, at most 1800s. A command that runs past it is killed
  and exits 124 — raise `--timeout` for builds and long tests.
- Output beyond 10 MB is dropped (a note says so); narrow it with `head`,
  `tail`, `grep`.

## 3. Move files

```sh
loom-node read  <device> <path> > local-file     # device → here
loom-node write <device> <path> < local-file     # here → device
```

Binary-safe. `write` creates parent directories and replaces the file
atomically. `~/…` and relative paths are relative to the device's home. To show
the user a file from their device, read it into your `output/` directory.

## Exit code 255

loom itself could not finish: the device is offline, unknown, or dropped the
connection mid-command (the command was killed on the device). stderr says
which. Run `loom-node list` to check that the device is back online before
retrying; if it stays offline, tell the user rather than retrying in a loop.
