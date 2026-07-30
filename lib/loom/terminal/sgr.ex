defmodule Loom.Terminal.Sgr do
  @moduledoc """
  Neovim emits 24-bit color SGR as colon-separated params without the ITU
  colorspace field, e.g. `ESC[38:2:R:G:Bm`. xterm.js parses colon-form
  truecolor as `38:2:<colorspace>:R:G:B` (6 segments) and therefore reads
  Neovim's R as the colorspace id, shifting the whole RGB by one → wrong color.

  We rewrite those into the unambiguous semicolon form `ESC[38;2;R;G;Bm`,
  which xterm.js parses correctly (verified against the same output an awk
  truecolor ramp produces).

  This is deliberately **stateless**: each PTY read is rewritten and forwarded
  immediately, nothing is buffered across reads. An earlier version held back a
  trailing partial escape sequence as "carry" to avoid splitting a truecolor
  token — but PTY reads almost never split escape sequences (measured 0/21),
  and holding back a trailing `ESC` delayed cursor-save/restore sequences
  (`ESC7`/`ESC8`) that TUIs like Claude Code use to pin their input box. Under
  network latency that delay desynced the redraw (input box repeated, lines
  misaligned). Not buffering is the right trade: at worst a truecolor token
  split across two reads misses its rewrite for one frame (a single wrong
  color, self-corrected on the next paint) — far cheaper than stalling control
  sequences.
  """

  @colon_truecolor ~r/(38|48):2:(\d{1,3}):(\d{1,3}):(\d{1,3})/

  @doc "Rewrite colon-form truecolor to semicolon form. Stateless, no buffering."
  @spec transform(binary) :: binary
  def transform(data) do
    Regex.replace(@colon_truecolor, data, fn _full, sel, r, g, b ->
      "#{sel};2;#{r};#{g};#{b}"
    end)
  end
end
