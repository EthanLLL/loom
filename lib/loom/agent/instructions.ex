defmodule Loom.Agent.Instructions do
  @moduledoc """
  What Loom tells the backend on top of its own system prompt: CC's
  `--append-system-prompt`, Codex's `developerInstructions`. Given at every
  spawn and resume, since no backend keeps it. Kiro has no such slot; it gets
  the text as steering (`_meta.kiro.steering`, `Loom.Agent.Backend.Kiro`).

  In order: where the agent is (Loom, how it is built, where its source is),
  this session's id and directory, why nothing may outlive a turn, how to read
  many images without overflowing the request, and where files for the user go.

  Paths are absolute rather than environment variables, because Codex runs
  every session's thread in one shared app-server — there is no per-session
  process to give an environment to.
  """

  alias Loom.Agent.Store

  # The checkout this was compiled from; a release is built in place, so it is
  # the source of what is running.
  @source Path.expand("../../..", __DIR__)

  @doc "The text for session `id`, whose backend is `backend`."
  def for_session(id, backend) when backend in [:claude_code, :codex, :kiro] do
    dir = Store.session_dir(id)
    output = Store.output_dir(id)

    """
    You are running inside Loom, a self-hosted web UI for coding agents. Loom \
    is an Elixir/Phoenix application on this machine: each session is a \
    process whose events reach the user's browsers over Phoenix PubSub and \
    Channels, so any of their devices can follow it live. #{runs_you(backend)} The user reads your replies in a browser and \
    cannot see this machine's filesystem. Loom's source is in #{@source}; \
    read it, and its docs/, when you need to know how Loom behaves.

    This session's id is #{id}. Its directory is #{dir}: files/ holds what \
    the user attached, output/ what you make for them; meta.json and \
    events.jsonl are Loom's own.

    ## Nothing outlives the turn

    Loom stops this backend process when the session sits idle and whenever \
    Loom restarts, so nothing started in the background — shell jobs, \
    subagents, timers — outlives the turn it was started in. The user sees in \
    the sidebar which sessions are working and spending; work that runs where \
    nobody can see it is not wanted here.

    So run subagents and commands in the foreground#{foreground(backend)} and \
    wait for them before ending the turn; several foreground subagents in one message still run in \
    parallel. This holds even when a skill or plugin says to dispatch \
    background agents: those were written for a terminal that stays open. \
    For work that must outlive the turn, start Loom sessions (the `sessions` \
    skill); for scheduled prompts and check-ins, use Loom's cron (the `cron` \
    skill).

    #{images(backend, dir)}#{config(backend)}
    ## Files for the user

    When you produce a file meant for the user — a spreadsheet, a slide deck, \
    a document, an image, an archive, anything they should download — save it \
    in #{output} (subdirectories are fine). Files written there are offered \
    to the user for download automatically when your turn ends; files written \
    anywhere else are not. Use descriptive file names. When you mention such \
    a file in your reply, link it as [name](output/<path relative to that \
    directory>).

    Next to the chat is a canvas: a browser pane. When something is better \
    seen than downloaded — a chart or dashboard, a gallery of images, a video, \
    a small web page — build it as a self-contained page: \
    #{output}/<name>/index.html with its assets beside it, referenced by \
    relative paths. The newest such index.html opens in the canvas by itself \
    when your turn ends; each subdirectory is shown as a single card (one \
    with an index.html opens as a page, any other is offered as a zip). The \
    page runs sandboxed with no access to Loom itself; it may load libraries \
    from public CDNs. Don't build a page when a plain file is what the user \
    asked for.
    """
  end

  defp runs_you(:claude_code) do
    "Loom runs you as Claude Code: the `claude` CLI behind an Erlang port, " <>
      "in stream-json over stdin/stdout, one process per session."
  end

  defp runs_you(:codex) do
    "Loom runs you as Codex: one `codex app-server` behind an Erlang port, " <>
      "JSON-RPC over stdin/stdout, every session a thread in it."
  end

  defp runs_you(:kiro) do
    "Loom runs you as Kiro: the `kiro-cli acp` agent behind an Erlang port, " <>
      "ACP JSON-RPC over stdin/stdout, one process per session."
  end

  # Kiro's engine refuses any file-tool write under `.kiro/settings`, with no
  # prompt and no override (measured). Its
  # own CLI is the sanctioned way to change the MCP config.
  defp config(:kiro) do
    """

    ## Kiro's own config

    Kiro refuses file-tool writes under ~/.kiro/settings (mcp.json, cli.json), \
    and no permission covers them. To change MCP servers, run `kiro-cli mcp \
    add`, `kiro-cli mcp remove` or `kiro-cli mcp list` in the shell (see \
    `kiro-cli mcp add --help`). Don't write those files any other way. A new \
    or changed server loads only when Loom starts a fresh kiro-cli, so then \
    ask the user to send /reload.
    """
  end

  defp config(_backend), do: ""

  defp foreground(:claude_code), do: " (`run_in_background` false, for Agent and Bash alike)"
  defp foreground(_backend), do: ""

  # Bedrock and the Anthropic API cap a request at about 32 MB, and every image
  # read rides along in every later request: past ~60 the session is dead.
  defp images(:claude_code, dir) do
    """
    ## Many images

    Every request carries the whole conversation, every image read so far \
    included, at roughly 0.3–0.7 MB each, and a request is capped at about \
    32 MB. Around 60 images read in this conversation, a turn fails with \
    "Input is too long" and the session cannot recover; /compact fails the \
    same way. So count the images already read here plus the ones the \
    current message would add:

    - 20 or fewer in total: read them directly.
    - More than 20, or 5 or more in one message: don't read them here. Hand \
    them to foreground subagents (Agent with `model: "sonnet"`; copying text \
    off a picture needs no bigger model), about 10 images each, in parallel. \
    Each transcribes what is on its images verbatim — numbers, names, table \
    structure, anything illegible marked as such, no conclusions — into a \
    Markdown file under #{dir}/files/transcripts/. Read only those files here.
    - To check one detail later, read that single image, never the batch again.
    - Once this conversation holds more than 40 images, ask the user to send \
    /compact, which clears them from the history.

    When the picture itself is the point (which photo looks better) and there \
    are only a few, read them directly; with many, have subagents describe \
    each first, then look at the few that matter.
    """
  end

  defp images(_backend, dir) do
    """
    ## Many images

    Every image read stays in the conversation and is paid for again on every \
    later turn. With more than a handful, write what each shows — numbers, \
    names, table structure verbatim, no conclusions — into a Markdown file \
    under #{dir}/files/transcripts/ as you go, and work from those files; \
    reread a single image only to check one detail.
    """
  end
end
