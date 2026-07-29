defmodule Loom.Terminal.Layout do
  @moduledoc """
  Holds the authoritative window layout so a reconnecting browser restores the
  same tabs, panes, left→right order, and active tab.

  Shape:

      %{
        tabs: [%{id: tab_id, panes: [session_id, ...]}, ...],
        active_tab: tab_id | nil
      }

  A pane maps 1:1 to a terminal session. Each tab holds up to 3 panes (enforced
  by the caller). This is in-memory state — it survives browser reconnects, not
  a server restart (the PTYs don't survive that either).
  """
  use GenServer

  @name __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: @name)

  @doc "Return the full layout."
  def get, do: GenServer.call(@name, :get)

  @doc "Replace the whole layout (client is the source of truth for arrangement)."
  def put(layout), do: GenServer.call(@name, {:put, layout})

  @impl true
  def init(_), do: {:ok, %{tabs: [], active_tab: nil}}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  def handle_call({:put, layout}, _from, _state) do
    normalized = %{
      tabs: normalize_tabs(layout["tabs"] || layout[:tabs] || []),
      active_tab: layout["active_tab"] || layout[:active_tab]
    }

    {:reply, :ok, normalized}
  end

  defp normalize_tabs(tabs) do
    Enum.map(tabs, fn tab ->
      %{
        id: tab["id"] || tab[:id],
        panes: tab["panes"] || tab[:panes] || []
      }
    end)
  end
end
