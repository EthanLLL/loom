# Keys

Desktop only; a phone layout has none of these. `?` in Loom lists them too.
**Vim mode** at the bottom of the sidebar turns them all off, `` Ctrl-` ``
included, and back on; it is remembered per browser.

## Where the keys go

There is no mode of its own: **where the focus is decides**, the way it does
in Vim.

- **Typing** — the composer, a rename box, a dialog, a shell: every key is
  typed as usual. The one exception is `` Ctrl-` ``, below.
- **Normal** — the focus anywhere else: keys are the commands below. Click on
  empty space, or press `Esc` in the composer, to get here.
- **The canvas** keeps every key while it has the focus (a sandboxed page can
  not hand them back). Click outside it to return. This is what lets `F` in a
  reveal.js deck go full screen.

## Normal

| Key | Does |
|---|---|
| `i` | Focus the composer |
| `Esc` (in the composer) | Leave it. With the command menu open, the first `Esc` closes the menu; while an IME is composing, `Esc` is the IME's |
| `j` / `k` | Scroll the conversation a little |
| `Ctrl-d` / `Ctrl-u` | Half a page down / up |
| `gg` / `G` | Top / bottom (at the bottom, new output is followed again) |
| `h` / `l` | Into the session list / the file tree, as `␣b` / `␣e` do |
| `J` / `K` | Next / previous session, in the sidebar's order |
| `?` | All keys; `Esc` or `?` closes it |

## Leader (Space)

After Space, a box in the bottom right lists what can follow. `Esc` gives up.

| Key | Does |
|---|---|
| `␣e` | The canvas's file tree; see below |
| `␣b` | The session list; see below |
| `␣t` | Terminals, shown or hidden. Showing them focuses the shell |
| `␣c` | The canvas, shown or hidden |
| `␣f` | The right-hand column across the whole window, or back (also `Esc`) |
| `␣nc` | New Claude Code session |
| `␣nx` | New Codex session |

## The session list (`␣b`)

`␣b` puts a cursor on the current session, opening the sidebar first if it is
hidden. Then:

| Key | Does |
|---|---|
| `j` / `k` | Move the cursor |
| `Enter` | Open that session |
| `Esc` or `l` | Leave the list for the chat, sidebar still shown |
| `␣b` | Leave the list and hide the sidebar |

A click anywhere also leaves it.

## The file tree (`␣e`)

`␣e` opens the canvas and its file tree as needed and puts a cursor on what the
canvas shows, or on the top row. Then:

| Key | Does |
|---|---|
| `j` / `k` | Move the cursor |
| `Enter` | A folder folds or unfolds; a file opens in the canvas (or downloads, if it has no viewer). The cursor stays, so `j` `Enter` `j` `Enter` pages through files |
| `l` | Unfold a folder, or step into an unfolded one; a file opens, as `Enter` |
| `h` | Fold an unfolded folder, or go up to the folder this row is in; at the top level, back to the chat |
| `Esc` | Leave the tree, still shown |
| `␣e` | Leave the tree and hide it |

A click anywhere also leaves it.

## Anywhere

| Key | Does |
|---|---|
| `` Ctrl-` `` | Terminals, shown or hidden — from a shell too, which is the only way to leave one without the mouse. Space can not do it: in a shell it is typed |
