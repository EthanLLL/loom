defmodule Loom.SearchTest do
  @moduledoc """
  Search reads the transcripts as rg finds them, and only counts what a person
  said or read: tool calls, their output and the JSON around a message are not
  hits.
  """
  use ExUnit.Case, async: false

  alias Loom.Search

  setup do
    data_dir = Path.join(System.tmp_dir!(), "loom-search-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:loom, Loom.Agent, [])
    Application.put_env(:loom, Loom.Agent, Keyword.put(previous, :data_dir, data_dir))

    on_exit(fn ->
      Application.put_env(:loom, Loom.Agent, previous)
      File.rm_rf(data_dir)
    end)

    write = fn id, events ->
      dir = Path.join(data_dir, id)
      File.mkdir_p!(dir)
      lines = for e <- events, do: [Jason.encode!(e), "\n"]
      File.write!(Path.join(dir, "events.jsonl"), lines)
    end

    {:ok, data_dir: data_dir, write: write}
  end

  defp event(seq, kind, payload), do: %{seq: seq, at: 1000 + seq, kind: kind, payload: payload}

  test "finds what was said, newest first, with a little either side", %{write: write} do
    write.("a_one", [
      event(1, "user", %{text: "帮我做一个体重表格"}),
      event(2, "tool_result", %{name: "Bash", text: "体重表格.xlsx written"}),
      event(3, "assistant_text", %{text: "Here is the 体重表格 you asked for."})
    ])

    write.("a_two", [event(1, "thinking", %{text: "体重表格 again"})])

    assert {:ok, hits} = Search.content("体重表格")

    assert [%{id: "a_one", seq: 3, kind: "assistant_text"}, %{id: "a_one", seq: 1, kind: "user"}] =
             hits

    assert %{before: "Here is the ", match: "体重表格", after: " you asked for."} = hd(hits)
  end

  test "case is ignored, and a JSON key is not a hit", %{write: write} do
    write.("a_one", [event(1, "user", %{text: "Open the Canvas"})])

    assert {:ok, [%{match: "Canvas"}]} = Search.content("canvas")
    assert {:ok, []} = Search.content("payload")
    assert {:ok, []} = Search.content("   ")
  end

  test "a quote or backslash is looked for as it is stored", %{write: write} do
    write.("a_one", [event(1, "user", %{text: ~S(say "hi" to C:\loom)})])

    assert {:ok, [_]} = Search.content(~S("hi"))
    assert {:ok, [_]} = Search.content(~S(C:\loom))
  end

  test "deleted sessions are not searched", %{data_dir: data_dir, write: write} do
    write.(".trash/a_gone.1", [event(1, "user", %{text: "needle"})])
    assert File.exists?(Path.join(data_dir, ".trash/a_gone.1/events.jsonl"))
    assert {:ok, []} = Search.content("needle")
  end
end
