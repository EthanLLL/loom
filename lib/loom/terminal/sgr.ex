defmodule Loom.Terminal.Sgr do
  @moduledoc """
  Neovim emits 24-bit color SGR as colon-separated params without the ITU
  colorspace field, e.g. `ESC[38:2:R:G:Bm`. xterm.js parses colon-form
  truecolor as `38:2:<colorspace>:R:G:B` (6 segments) and therefore reads
  Neovim's R as the colorspace id, shifting the whole RGB by one → wrong color.

  We rewrite those into the unambiguous semicolon form `ESC[38;2;R;G;Bm`,
  which xterm.js parses correctly (verified against the same output an awk
  truecolor ramp produces).

  A CSI sequence may be split across PTY reads, so `transform/2` holds back any
  trailing incomplete escape sequence and returns it as carry for next time.
  """

  @colon_truecolor ~r/(38|48):2:(\d{1,3}):(\d{1,3}):(\d{1,3})/

  @doc """
  Rewrite colon-form truecolor in `carry <> data`, returning
  `{output, new_carry}` where `new_carry` is a trailing partial escape sequence
  to prepend next time.
  """
  @spec transform(binary, binary) :: {binary, binary}
  def transform(data, carry \\ "") do
    combined = carry <> data
    {ready, new_carry} = split_trailing_partial(combined)
    {rewrite(ready), new_carry}
  end

  defp rewrite(data) do
    Regex.replace(@colon_truecolor, data, fn _full, sel, r, g, b ->
      "#{sel};2;#{r};#{g};#{b}"
    end)
  end

  # If the data ends inside an unterminated CSI sequence (an ESC or `ESC[...`
  # with no final byte yet), hold it back so we never rewrite half a sequence.
  defp split_trailing_partial(data) do
    case :binary.matches(data, "\e") do
      [] ->
        {data, ""}

      matches ->
        {last_esc, _} = List.last(matches)
        tail = binary_part(data, last_esc, byte_size(data) - last_esc)

        if complete_csi?(tail) do
          {data, ""}
        else
          {binary_part(data, 0, last_esc), tail}
        end
    end
  end

  # A CSI sequence `ESC [ params ... final` ends with a byte in 0x40..0x7E.
  # Treat anything already terminated (or not a CSI at all) as complete.
  defp complete_csi?(<<"\e[", rest::binary>>), do: has_final_byte?(rest)
  defp complete_csi?(<<"\e", _::binary>>), do: false
  defp complete_csi?(_), do: true

  defp has_final_byte?(<<>>), do: false

  defp has_final_byte?(<<byte, rest::binary>>) do
    if byte in 0x40..0x7E, do: true, else: has_final_byte?(rest)
  end
end
