defmodule Loom.Agent.Profiles do
  @moduledoc """
  Profiles: which model provider a session talks to, one directory per backend
  under `~/.loom/profiles/`.

  ## Claude Code: `profiles/claude_code/<name>.json`

  A Claude Code settings file, handed to the CLI as `--settings`. Its `env`
  overrides the machine's own `~/.claude/settings.json`, so a profile that says

      {"env": {"CLAUDE_CODE_USE_BEDROCK": "0",
               "ANTHROPIC_BASE_URL": "https://…",
               "ANTHROPIC_AUTH_TOKEN": "…"}}

  sends that session to another endpoint while every other session keeps the
  default. Measured: the request goes to `<base>/v1/messages` with
  `Authorization: Bearer <token>`, and the model names in the profile are sent
  as written.

  ## Codex: `profiles/codex/<name>.json`

      {"base_url": "https://…/v1", "api_key": "sk-…",
       "models": ["gpt-6.2-sol", "gpt-6.1-sol"]}

  An OpenAI-compatible endpoint serving the Responses API, and the models a
  session on it may pick, the first the default. Chosen once, when the profile
  is made: the endpoint's own `/v1/models` lists far more than Codex can run,
  and is never asked at run time. Optional `http_headers`, sent with every
  request. See `Loom.Agent.Backend.Codex`.

  ## Both

  Nothing is copied out of the file: the session records only the name, and the
  backend reads the file whenever it starts or resumes, so an edit takes effect
  then and the key never enters a session header.

  No directory, no profiles: the session list offers only the default.
  """

  alias Loom.Agent.Store

  @name ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  # The backends that take one, each with a directory of its own name.
  @backends [:claude_code, :codex]

  @doc "Where `backend`'s profiles are kept."
  def dir(backend) when backend in @backends,
    do: Path.join([Store.home(), "profiles", Atom.to_string(backend)])

  @doc "Every profile on disk, by backend, then name."
  @spec list() :: [%{name: String.t(), backend: atom()}]
  def list do
    for backend <- @backends, name <- names(backend), do: %{name: name, backend: backend}
  end

  defp names(backend) do
    Path.join(dir(backend), "*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.filter(&valid_name?/1)
    |> Enum.sort()
  end

  @doc "Whether `name` could name a profile at all."
  def valid_name?(name), do: is_binary(name) and Regex.match?(@name, name)

  @doc "The file for `backend`'s profile `name`, if it exists."
  @spec path(atom(), String.t()) :: {:ok, Path.t()} | {:error, String.t()}
  def path(backend, name) when backend in @backends do
    file = Path.join(dir(backend), name <> ".json")

    cond do
      not valid_name?(name) -> {:error, "invalid profile name #{inspect(name)}"}
      File.regular?(file) -> {:ok, file}
      true -> {:error, "profile #{name} not found in #{dir(backend)}"}
    end
  end

  def path(backend, _name), do: {:error, "#{backend} sessions take no profile"}

  @doc "A Codex profile, read and checked."
  @spec codex(String.t()) ::
          {:ok,
           %{base_url: String.t(), api_key: String.t(), models: [String.t()], headers: map()}}
          | {:error, String.t()}
  def codex(name) do
    with {:ok, file} <- path(:codex, name),
         {:ok, body} <- File.read(file),
         {:ok,
          %{"base_url" => "http" <> _ = url, "api_key" => key, "models" => [_ | _] = models} =
            profile}
         when is_binary(key) <- Jason.decode(body),
         true <- Enum.all?(models, &is_binary/1),
         headers when is_map(headers) <- Map.get(profile, "http_headers", %{}) do
      {:ok, %{base_url: url, api_key: key, models: models, headers: headers}}
    else
      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      _ ->
        {:error, "profile #{name} needs base_url, api_key and a list of models"}
    end
  end
end
