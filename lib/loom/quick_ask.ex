defmodule Loom.QuickAsk do
  @moduledoc """
  Quick Ask: a message into a new session with nothing to pick first, as Siri
  and Shortcuts on the iPhone send it. Which backend and model that session
  gets is this Loom's setting, kept in `quick-ask.json` under
  `Loom.Agent.Store.home/0`; until it is set, Claude Code on Sonnet. A `nil`
  model is the backend's own default.
  """

  alias Loom.Agent
  alias Loom.Agent.Backend

  @default %{backend: :claude_code, model: "sonnet"}

  def path,
    do:
      Application.get_env(:loom, __MODULE__, [])[:path] ||
        Path.join(Agent.Store.home(), "quick-ask.json")

  @doc "The current setting, `%{backend:, model:}`."
  def settings do
    with {:ok, body} <- File.read(path()),
         {:ok, %{"backend" => name} = saved} <- Jason.decode(body),
         {:ok, backend} <- Backend.parse(name) do
      %{backend: backend, model: saved["model"]}
    else
      _ -> @default
    end
  end

  @doc "Change the setting; the model must be one the backend lists, or `nil`."
  def put_settings(name, model) do
    with {:ok, backend} <- parse(name),
         :ok <- check_model(backend, model) do
      settings = %{backend: backend, model: model}
      tmp = path() <> ".tmp"
      File.mkdir_p!(Path.dirname(tmp))
      File.write!(tmp, Jason.encode_to_iodata!(settings, pretty: true))
      File.rename!(tmp, path())
      {:ok, settings}
    end
  end

  @doc """
  Start a session as the setting says and send it `text`; returns `{:ok, id}`.
  A model the backend no longer lists is refused before anything is started.
  """
  def ask(text, opts \\ []) do
    %{backend: backend, model: model} = settings()

    with :ok <- check_model(backend, model) do
      Agent.new_session(nil, text, backend: backend, model: model, origin: opts[:origin])
    end
  end

  defp parse(name) do
    case Backend.parse(name) do
      {:ok, backend} -> {:ok, backend}
      :error -> {:error, "unknown backend #{inspect(name)}"}
    end
  end

  defp check_model(_backend, nil), do: :ok

  defp check_model(backend, model) do
    if Enum.any?(Agent.models(backend), &(&1.id == model)),
      do: :ok,
      else: {:error, "#{Backend.label(backend)} has no model #{inspect(model)}"}
  end
end
