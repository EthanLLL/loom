defmodule LoomWeb.AgentSessionController do
  use LoomWeb, :controller

  alias Loom.Agent

  # GET /api/agents — list live agent sessions.
  def index(conn, _params) do
    json(conn, %{sessions: Enum.map(Agent.list_sessions(), &view/1)})
  end

  # POST /api/agents — start a session.
  #
  # `backend` is required: `claude_code` or `codex`. There is no default,
  # because the choice is permanent — the conversation lives in that engine's
  # own store, so switching later would mean abandoning the history. Better to
  # make the caller say which one than to quietly pick for them.
  #
  # Deliberately takes no directory. A session has no project root: which
  # project is being worked on is a fact in the conversation, and the model
  # composes absolute paths from it. A channel only ever attaches to an existing
  # session, so creation goes through here.
  #
  # `profile` optionally names a `Loom.Agent.Profiles` file, Claude Code only.
  # It is as permanent as the backend.
  def create(conn, params) do
    case Loom.Agent.Backend.parse(params["backend"]) do
      {:ok, backend} ->
        case check_profile(backend, params["profile"]) do
          :ok -> create_session(conn, backend, params)
          {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
        end

      :error ->
        bad_backend(conn, params["backend"])
    end
  end

  # GET /api/profiles — the profiles a new Claude Code session can use.
  def profiles(conn, _params) do
    json(conn, %{profiles: Loom.Agent.Profiles.list()})
  end

  # GET /api/models?backend=… — what a session of that kind can be switched to.
  def models(conn, params) do
    case Loom.Agent.Backend.parse(params["backend"]) do
      {:ok, backend} -> json(conn, %{models: Agent.models(backend)})
      :error -> bad_backend(conn, params["backend"])
    end
  end

  defp check_profile(_backend, nil), do: :ok

  defp check_profile(:claude_code, name) do
    with {:ok, _file} <- Loom.Agent.Profiles.path(name), do: :ok
  end

  defp check_profile(_backend, _name), do: {:error, "only Claude Code sessions take a profile"}

  defp create_session(conn, backend, params) do
    id = generate_id()
    opts = [{:backend, backend} | build_opts(params)]

    case Agent.start_session(id, opts) do
      {:ok, _pid} ->
        conn |> put_status(:created) |> json(view(Agent.info(id)))

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  defp bad_backend(conn, given) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: "`backend` must be \"claude_code\" or \"codex\"",
      given: given
    })
  end

  # PATCH /api/agents/:id with `directory` — file it elsewhere in the session
  # list (`""` is the root). See `Loom.Agent.Directory`.
  def update(conn, %{"id" => id, "directory" => directory}) do
    case Agent.move(id, directory) do
      :ok -> json(conn, view(Agent.info(id)))
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
    end
  end

  # PATCH /api/agents/:id with `model` — from the next turn on.
  def update(conn, %{"id" => id, "model" => model}) do
    case Agent.set_model(id, model) do
      :ok -> json(conn, view(Agent.info(id)))
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
    end
  end

  # PATCH /api/agents/:id with `title` — rename. Local to loom; never pushed to
  # the backend.
  def update(conn, %{"id" => id, "title" => title}) do
    case Agent.rename(id, title) do
      :ok -> json(conn, view(Agent.info(id)))
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
    end
  end

  # DELETE /api/agents/:id — stop the session *and* discard its history.
  #
  # Stopping without deleting would be a trap in a UI: the session vanishes
  # from the list, then comes back at the next boot because `Agent.Bootstrap`
  # restores everything on disk.
  def delete(conn, %{"id" => id}) do
    Agent.delete_session(id)
    send_resp(conn, :no_content, "")
  end

  # POST /api/directories/move — rename a directory, or move it with everything
  # under it: `from` and `to` are whole paths.
  def move_directory(conn, %{"from" => from, "to" => to}) do
    case Agent.move_directory(from, to) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
    end
  end

  defp build_opts(params) do
    []
    |> maybe_put(:title, params["title"])
    |> maybe_put(:profile, params["profile"])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, val), do: [{key, val} | opts]

  defp generate_id do
    "a_" <> (:crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false))
  end

  defp view(info) do
    %{
      id: info.id,
      title: info.title,
      directory: info.directory,
      backend: info.backend,
      backend_label: info.backend_label,
      profile: info.profile,
      model: info.model,
      created_at: info.created_at,
      last_active_at: info.last_active_at,
      status: info.status,
      queued: info.queued,
      queue: info.queue,
      usage: info.usage,
      context_tokens: info.context_tokens,
      context_window: info.context_window,
      turns: info.turns,
      seq: info.seq
    }
  end
end
