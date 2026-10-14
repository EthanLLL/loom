defmodule LoomWeb.AgentFileController do
  @moduledoc """
  Uploads for one session's attachments.

  Separate from the channel on purpose: a WebSocket frame is a poor transport
  for a 20 MB screenshot (it would sit in front of every event and delta on the
  same socket), and multipart gives us the upload already spooled to a temp file
  instead of base64 in memory.

  The response carries the absolute paths. The client hands them back with the
  next `submit`, where `Loom.Agent.Files.verify/2` checks they are this
  session's own before the model is told about them.
  """
  use LoomWeb, :controller

  require Logger

  alias Loom.Agent
  alias Loom.Agent.Files

  # POST /api/agents/:id/files — multipart, one or many `files[]`.
  def create(conn, %{"id" => id} = params) do
    cond do
      # Also what keeps the id from being a path: an unknown one has no process.
      not Agent.exists?(id) ->
        conn |> put_status(:not_found) |> json(%{error: "unknown session"})

      uploads(params) == [] ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "no files in the request"})

      true ->
        store_all(conn, id, uploads(params))
    end
  end

  defp store_all(conn, id, uploads) do
    results = Enum.map(uploads, &Files.store(id, &1))

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        json(conn, %{files: Enum.map(results, fn {:ok, file} -> file end)})

      {:error, reason} ->
        # All or nothing: a half-attached drop would leave the user guessing
        # which of the five files the agent is about to see.
        for {:ok, file} <- results, do: File.rm(file.path)
        conn |> put_status(status_for(reason)) |> json(%{error: message_for(reason)})
    end
  end

  defp status_for(:too_large), do: :request_entity_too_large
  defp status_for(_other), do: :unprocessable_entity

  defp message_for(:too_large), do: "a file is larger than 25 MB"
  defp message_for(:empty), do: "a file is empty"
  defp message_for(reason), do: "could not store the file: #{inspect(reason)}"

  # `files[]` is the normal case; `file` is accepted so a one-off `curl -F` works.
  defp uploads(params) do
    [Map.get(params, "files"), Map.get(params, "file")]
    |> Enum.flat_map(fn
      %Plug.Upload{} = upload -> [upload]
      list when is_list(list) -> Enum.filter(list, &match?(%Plug.Upload{}, &1))
      _ -> []
    end)
  end
end
