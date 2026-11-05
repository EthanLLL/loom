defmodule Loom.Search do
  @moduledoc """
  Full-text search over every session's transcript, by ripgrep.

  The transcripts are plain files (`Loom.Agent.Store`), so the fastest thing
  that can search them is a tool built for searching files, not a loop here:
  rg reads a family machine's 18 MB of `events.jsonl` in a few milliseconds.
  It is found on `PATH` and not bundled; without it, search says so.

  What rg sees is JSON, so the query is matched in the form it is stored in —
  a `"` in it is looked for as `\\"`. A line rg returns is then decoded, and only
  counts if it is something a person said or read: the user's messages and the
  agent's replies. Tool calls, their output and thinking are most of the bytes
  and almost all of the noise, and the match is checked again in the decoded
  text, so a hit on a JSON key (`text`, `kind`) is not a hit.

  Each search runs under its own process, and a new one from the same client
  kills the old (`LoomWeb.LobbyChannel`) — typing is many searches in a row,
  and only the last one is wanted.
  """

  alias Loom.Agent.Store

  @timeout 3_000
  @max_hits 100
  @kinds ["user", "assistant_text"]
  @context_before 40
  @context_after 80

  @doc """
  Hits for `query`, newest first: `%{id:, seq:, at:, kind:, before:, match:,
  after:}`, the match with a little of its message either side.
  """
  def content(query) when is_binary(query) do
    query = String.trim(query)

    cond do
      query == "" -> {:ok, []}
      rg = System.find_executable("rg") -> run(rg, query)
      true -> {:error, :no_rg}
    end
  end

  defp run(rg, query) do
    # As `Jason` writes it into the transcript, minus the quotes around it.
    needle = query |> Jason.encode!() |> String.slice(1..-2//1)

    args = [
      "--json",
      "--fixed-strings",
      "--ignore-case",
      "--max-count",
      "200",
      # A session's own transcript and nothing else: one level down, so not
      # anything the agent wrote into `output/`, and not `.trash`, which is
      # hidden and so skipped by rg.
      "--glob",
      "events.jsonl",
      "--max-depth",
      "2",
      "--",
      needle,
      Store.data_dir()
    ]

    task = Task.async(fn -> System.cmd(rg, args, stderr_to_stdout: false) end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      # 1 is "nothing matched".
      {:ok, {out, status}} when status in [0, 1] -> {:ok, hits(out, query)}
      {:ok, {_out, status}} -> {:error, {:rg_failed, status}}
      nil -> {:error, :timeout}
    end
  end

  defp hits(out, query) do
    pattern = Regex.compile!(Regex.escape(query), "iu")

    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&hit(&1, pattern))
    |> Enum.sort_by(& &1.at, :desc)
    |> Enum.take(@max_hits)
  end

  defp hit(line, pattern) do
    with {:ok, %{"type" => "match", "data" => data}} <- Jason.decode(line),
         %{"path" => %{"text" => path}, "lines" => %{"text" => text}} <- data,
         {:ok, %{"kind" => kind, "payload" => %{"text" => message}} = event} <- Jason.decode(text),
         true <- kind in @kinds and is_binary(message),
         [{start, len}] <- Regex.run(pattern, message, return: :index) do
      [
        %{
          id: path |> Path.dirname() |> Path.basename(),
          seq: event["seq"],
          at: event["at"],
          kind: kind,
          before: message |> binary_part(0, start) |> tail(@context_before),
          match: binary_part(message, start, len),
          after:
            message
            |> binary_part(start + len, byte_size(message) - start - len)
            |> String.slice(0, @context_after)
        }
      ]
    else
      _ -> []
    end
  end

  defp tail(text, n), do: text |> String.graphemes() |> Enum.take(-n) |> Enum.join()
end
