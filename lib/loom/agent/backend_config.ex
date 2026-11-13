defmodule Loom.Agent.BackendConfig do
  @moduledoc """
  Loom's own per-backend settings: `~/.loom/backends/<kind>.json`.

  For a backend whose CLI keeps no default of its own that Loom can rely on:
  Kiro's ACP engine ignores `chat.defaultModel` (measured), so this is where
  its model goes. Only Kiro reads it today; Claude Code has profiles
  (`Loom.Agent.Profiles`), and Codex its `config.toml`. One file per backend,
  one shape, so a later backend with the same gap needs no new mechanism:

      {
        "model": "claude-opus-5.5",
        "effort": "high",
        "args": [],
        "env": {"SOME_KEY": "…"}
      }

  Every key is optional; what each means is up to the adapter (Kiro sends
  `model` and `effort` as ACP config options and appends `args`). `env`
  reaches only that backend's own processes.

  Read afresh at every spawn, so an edit applies without restarting Loom:
  after `/reload`, or once the session has idled. A file that is missing is
  no settings; one that cannot be read is logged and ignored, never fatal.
  """

  require Logger

  alias Loom.Agent.Backend

  @type t :: %{
          model: String.t() | nil,
          effort: String.t() | nil,
          args: [String.t()],
          env: %{String.t() => String.t()}
        }

  @doc "The directory holding the files: `<LOOM_HOME>/backends`."
  def dir, do: Path.join(Loom.Agent.Store.home(), "backends")

  @doc "The file for `kind`."
  def path(kind), do: Path.join(dir(), "#{kind}.json")

  @doc "Settings for `kind`, with every key present."
  @spec get(Backend.kind()) :: t()
  def get(kind) do
    kind |> path() |> read() |> normalize(path(kind))
  end

  defp read(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{} = map} ->
            map

          {:ok, _other} ->
            Logger.warning("BackendConfig: #{path} is not a JSON object; ignored")
            %{}

          {:error, error} ->
            Logger.warning(
              "BackendConfig: #{path} is not valid JSON (#{Exception.message(error)}); ignored"
            )

            %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("BackendConfig: cannot read #{path}: #{inspect(reason)}")
        %{}
    end
  end

  defp normalize(map, path) do
    %{
      model: string(map["model"], "model", path),
      effort: string(map["effort"], "effort", path),
      args: strings(map["args"], path),
      env: env(map["env"], path)
    }
  end

  defp string(nil, _key, _path), do: nil

  defp string(value, _key, _path) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string(value, key, path) do
    Logger.warning("BackendConfig: #{key} in #{path} is not a string: #{inspect(value)}; ignored")
    nil
  end

  defp strings(nil, _path), do: []

  defp strings(list, path) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      list
    else
      Logger.warning("BackendConfig: args in #{path} must all be strings; ignored")
      []
    end
  end

  defp strings(other, path) do
    Logger.warning("BackendConfig: args in #{path} is not a list: #{inspect(other)}; ignored")
    []
  end

  defp env(nil, _path), do: %{}

  defp env(%{} = map, path) do
    {good, bad} = Enum.split_with(map, fn {k, v} -> is_binary(k) and is_binary(v) end)

    if bad != [] do
      Logger.warning(
        "BackendConfig: env in #{path} has non-string values for #{inspect(Enum.map(bad, &elem(&1, 0)))}; those are ignored"
      )
    end

    Map.new(good)
  end

  defp env(other, path) do
    Logger.warning("BackendConfig: env in #{path} is not an object: #{inspect(other)}; ignored")
    %{}
  end
end
