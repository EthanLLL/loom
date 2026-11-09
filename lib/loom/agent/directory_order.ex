defmodule Loom.Agent.DirectoryOrder do
  @moduledoc """
  The order of the sidebar's directories, as the user dragged them: one list
  of paths in `~/.loom/directories.json`, the same on every device.

  Only a sort key. Directories stay prefixes on the sessions
  (`Loom.Agent.Directory`): a path here that no session is in shows nothing,
  and a directory not here goes after those that are, in code point order. So
  the list never has to be kept in step with the sessions; the one thing that
  touches it besides a drag is a rename, which carries the name along.

  Broadcasts `{:directory_order, paths}` on the lobby topic on every change.
  """
  use GenServer

  require Logger

  alias Loom.Agent.Directory

  @name __MODULE__
  @limit 500

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  def path, do: Application.get_env(:loom, __MODULE__, [])[:path] || default_path()

  defp default_path, do: Path.join(Loom.Agent.Store.home(), "directories.json")

  @doc "The paths, first to last."
  def list(server \\ @name), do: GenServer.call(server, :list)

  @doc """
  Replace the order with `paths`, as the sidebar sends it after a drag.
  Normalized, root and duplicates dropped; anything that is not a path is
  `{:error, :invalid_directory}`.
  """
  def put(paths, server \\ @name), do: GenServer.call(server, {:put, paths})

  @doc "A directory moved from `from` to `to`: whatever was under it follows."
  def rebase(from, to, server \\ @name), do: GenServer.call(server, {:rebase, from, to})

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, path())
    {:ok, %{path: path, paths: load(path)}}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, state.paths, state}

  def handle_call({:put, paths}, _from, state) when is_list(paths) and length(paths) <= @limit do
    normalized = Enum.map(paths, &Directory.normalize/1)

    if Enum.all?(normalized, &match?({:ok, _}, &1)),
      do: {:reply, :ok, update(state, for({:ok, p} <- normalized, do: p))},
      else: {:reply, {:error, :invalid_directory}, state}
  end

  def handle_call({:put, _paths}, _from, state), do: {:reply, {:error, :invalid_directory}, state}

  def handle_call({:rebase, from, to}, _from, state) do
    paths =
      Enum.map(state.paths, fn p ->
        case Directory.rebase(p, from, to) do
          {:ok, new} -> new
          :unchanged -> p
        end
      end)

    {:reply, :ok, update(state, paths)}
  end

  # A merge leaves two entries the same: the first keeps its place.
  defp update(state, paths) do
    paths = paths |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    if paths == state.paths do
      state
    else
      save(state.path, paths)
      Phoenix.PubSub.broadcast(Loom.PubSub, Loom.Agent.lobby_topic(), {:directory_order, paths})
      %{state | paths: paths}
    end
  end

  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"order" => paths}} when is_list(paths) <- Jason.decode(body) do
      Enum.filter(paths, &is_binary/1)
    else
      {:error, :enoent} ->
        []

      _ ->
        Logger.error("Loom.Agent.DirectoryOrder cannot read #{path}; starting from none")
        []
    end
  end

  defp save(path, paths) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode_to_iodata!(%{order: paths}, pretty: true))
    File.rename!(tmp, path)
  end
end
