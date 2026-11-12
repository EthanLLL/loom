defmodule Loom.Agent.Profiles do
  @moduledoc """
  Claude Code profiles: which model provider a session talks to.

  A profile is a Claude Code settings file, `~/.loom/profiles/<name>.json`,
  handed to the CLI as `--settings`. Its `env` overrides the machine's own
  `~/.claude/settings.json`, so a profile that says

      {"env": {"CLAUDE_CODE_USE_BEDROCK": "0",
               "ANTHROPIC_BASE_URL": "https://…",
               "ANTHROPIC_AUTH_TOKEN": "…"}}

  sends that session to another endpoint while every other session keeps the
  default. Measured: the request goes to `<base>/v1/messages` with
  `Authorization: Bearer <token>`, and the model names in the profile are sent
  as written.

  Nothing is copied out of the file: the session records only the name, and the
  CLI reads the file on each spawn, so editing a profile takes effect at the
  next spawn and the key never enters a session header.

  No directory, no profiles: the session list offers only the default.
  """

  alias Loom.Agent.Store

  @name ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  @doc "Where profiles are kept."
  def dir, do: Path.join(Store.home(), "profiles")

  @doc "Names of the profiles on disk, sorted."
  @spec list() :: [String.t()]
  def list do
    Path.join(dir(), "*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.filter(&valid_name?/1)
    |> Enum.sort()
  end

  @doc "Whether `name` could name a profile at all."
  def valid_name?(name), do: is_binary(name) and Regex.match?(@name, name)

  @doc "The settings file for `name`, if it exists."
  @spec path(String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def path(name) do
    file = Path.join(dir(), name <> ".json")

    cond do
      not valid_name?(name) -> {:error, "invalid profile name #{inspect(name)}"}
      File.regular?(file) -> {:ok, file}
      true -> {:error, "profile #{name} not found in #{dir()}"}
    end
  end
end
