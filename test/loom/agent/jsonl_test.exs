defmodule Loom.Agent.JsonlTest do
  @moduledoc """
  Line framing over a port. The case that matters is the one that only shows up
  under load: a message split across two reads.
  """
  use ExUnit.Case, async: true

  alias Loom.Agent.Jsonl

  doctest Loom.Agent.Jsonl

  test "a complete buffer leaves nothing behind" do
    assert Jsonl.split("{\"a\":1}\n{\"b\":2}\n") == {["{\"a\":1}", "{\"b\":2}"], ""}
  end

  test "a partial trailing line is carried over" do
    {lines, rest} = Jsonl.split("{\"a\":1}\n{\"b\"")
    assert lines == ["{\"a\":1}"]
    # Prepending this to the next chunk is the whole point: a long tool result
    # will not arrive in one read.
    assert rest == "{\"b\""
    assert Jsonl.split(rest <> ":2}\n") == {["{\"b\":2}"], ""}
  end

  test "blank lines are dropped" do
    assert Jsonl.split("\n\n{\"a\":1}\n\n") == {["{\"a\":1}"], ""}
  end

  test "an empty buffer is not an error" do
    assert Jsonl.split("") == {[], ""}
  end

  test "a line with no newline yet produces nothing" do
    assert Jsonl.split("{\"half\":") == {[], "{\"half\":"}
  end

  test "line/1 round-trips through split/1" do
    encoded = Jsonl.line(%{"method" => "turn/start"}) |> IO.iodata_to_binary()
    assert {[line], ""} = Jsonl.split(encoded)
    assert Jason.decode!(line) == %{"method" => "turn/start"}
  end
end
