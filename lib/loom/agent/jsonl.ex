defmodule Loom.Agent.Jsonl do
  @moduledoc """
  Newline-delimited JSON over a port, which is what both backends speak.

  A port delivers arbitrary byte chunks, not lines. Decoding per chunk would
  drop every message that happens to straddle a read — and the long messages are
  precisely the ones that matter (a tool result with a file in it, a patch).
  So a partial trailing line is carried over to the next chunk.
  """

  @doc """
  Split a buffer into complete lines plus whatever is left over.

  The leftover is never a complete line, so it is safe to prepend to the next
  chunk. Blank lines are dropped: both CLIs emit them and they carry nothing.

      iex> Loom.Agent.Jsonl.split("{\\"a\\":1}\\n{\\"b\\"")
      {["{\\"a\\":1}"], "{\\"b\\""}
  """
  @spec split(binary()) :: {[binary()], binary()}
  def split(buffer) when is_binary(buffer) do
    parts = String.split(buffer, "\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)
    {Enum.reject(complete, &(&1 == "")), rest}
  end

  @doc "Encode one message as a line ready for `Port.command/2`."
  @spec line(term()) :: iodata()
  def line(message), do: [Jason.encode_to_iodata!(message), ?\n]
end
