defmodule LoomWeb.DevicesController do
  @moduledoc """
  The Devices dialog's API: register, rename and remove the machines in
  `Loom.Nodes`. The list itself, and who is online, arrive over the lobby
  channel; these answer only so the dialog can show the result at once.

  Registering a device, or asking to reinstall one, returns an install `code`.
  The dialog turns it into `curl -fsSL <origin>/node/install/<code> | sh`; see
  `LoomWeb.NodeInstallController`.
  """
  use LoomWeb, :controller

  alias Loom.Nodes

  def index(conn, _params), do: json(conn, %{nodes: Nodes.list()})

  def create(conn, params) do
    case Nodes.create(params["name"]) do
      {:ok, node, code} -> conn |> put_status(201) |> json(%{node: node, code: code})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Nodes.rename(id, params["name"]) do
      {:ok, node} -> json(conn, %{node: node})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def delete(conn, %{"id" => id}) do
    case Nodes.delete(id) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def install(conn, %{"id" => id}) do
    case Nodes.install_code(id) do
      {:ok, code} -> json(conn, %{code: code})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp refuse(conn, :not_found), do: conn |> put_status(404) |> json(%{error: "no such device"})
  defp refuse(conn, reason), do: conn |> put_status(422) |> json(%{error: reason})
end
