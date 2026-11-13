defmodule Loom.Agent.InstructionsTest do
  use ExUnit.Case, async: true

  alias Loom.Agent.Instructions
  alias Loom.Agent.Store

  test "they say where the agent is, and where Loom's source is" do
    text = Instructions.for_session("a_in", :claude_code)
    assert text =~ "You are running inside Loom"
    assert text =~ "Loom's source is in #{File.cwd!()};"
  end

  test "they give the session's id and directory" do
    text = Instructions.for_session("a_in", :claude_code)
    assert text =~ "This session's id is a_in."
    assert text =~ "Its directory is #{Store.session_dir("a_in")}:"
  end

  test "they keep work in the turn and send lasting work through Loom" do
    text = Instructions.for_session("a_in", :claude_code)
    assert text =~ "run subagents and commands in the foreground"
    assert text =~ "`sessions` skill"
    assert text =~ "`cron` skill"
  end

  test "they send many images to subagents, transcripts into files/" do
    text = Instructions.for_session("a_in", :claude_code)
    assert text =~ "## Many images"
    assert text =~ "#{Store.session_dir("a_in")}/files/transcripts/"
  end

  test "Claude Code and Codex are each told what they are" do
    cc = Instructions.for_session("a_in", :claude_code)
    codex = Instructions.for_session("a_in", :codex)
    assert cc =~ "Loom runs you as Claude Code"
    assert cc =~ "32 MB"
    assert codex =~ "Loom runs you as Codex"
    refute codex =~ "32 MB"
    refute codex =~ "run_in_background"
    assert codex =~ "#{Store.session_dir("a_in")}/files/transcripts/"
  end

  test "they name the output directory, the link form and the canvas" do
    dir = Store.output_dir("a_in")
    text = Instructions.for_session("a_in", :claude_code)
    assert text =~ dir
    assert text =~ "(output/"
    assert text =~ "#{dir}/<name>/index.html"
  end

  test "Kiro is told what it is" do
    kiro = Instructions.for_session("a_in", :kiro)
    assert kiro =~ "Loom runs you as Kiro"
    assert kiro =~ "`kiro-cli mcp add`"
    assert kiro =~ "/reload"
    refute Instructions.for_session("a_in", :claude_code) =~ "kiro-cli mcp"
    refute kiro =~ "32 MB"
    refute kiro =~ "run_in_background"
    assert kiro =~ "#{Store.session_dir("a_in")}/files/transcripts/"
  end
end
