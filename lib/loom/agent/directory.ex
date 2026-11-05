defmodule Loom.Agent.Directory do
  @moduledoc """
  Directories for the session list, the way S3 has them: a prefix on each
  session, not a thing of their own.

  A session's `directory` is a path like `"work/aws"`, or `""` for the root.
  A directory exists exactly while some session's path is it or starts with
  it: nothing records one being made, and it is gone once its last session
  moves out. So there is no "create", no "delete if empty", and no state to
  fall out of step with the sessions.

  Only the header changes. The session keeps its id and its directory on disk,
  so its URL, cron jobs aimed at it, the backend's transcript and its output
  paths all stay where they were.
  """

  @segment_limit 80
  @depth_limit 10

  @doc """
  Clean up a path someone typed: segments trimmed, empty ones (`a//b`, a
  leading or trailing `/`) dropped. `""` is the root.
  """
  def normalize(path) when is_binary(path) do
    segments =
      path
      |> String.split("/")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      Enum.any?(segments, &(&1 in [".", ".."])) -> {:error, :invalid_directory}
      Enum.any?(segments, &(String.length(&1) > @segment_limit)) -> {:error, :invalid_directory}
      length(segments) > @depth_limit -> {:error, :invalid_directory}
      true -> {:ok, Enum.join(segments, "/")}
    end
  end

  def normalize(nil), do: {:ok, ""}
  def normalize(_other), do: {:error, :invalid_directory}

  @doc "Whether `path` is `dir` itself or somewhere under it."
  def within?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  @doc """
  Where `path` ends up when the directory `from` becomes `to`, or `:unchanged`
  when it is not under `from`. Moving the root is not a thing.
  """
  def rebase(_path, "", _to), do: :unchanged

  def rebase(path, from, to) do
    cond do
      path == from ->
        {:ok, to}

      String.starts_with?(path, from <> "/") ->
        {:ok, join(to, String.replace_prefix(path, from <> "/", ""))}

      true ->
        :unchanged
    end
  end

  defp join("", rest), do: rest
  defp join(dir, rest), do: dir <> "/" <> rest
end
