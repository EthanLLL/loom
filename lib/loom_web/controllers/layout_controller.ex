defmodule LoomWeb.LayoutController do
  use LoomWeb, :controller

  alias Loom.Terminal
  alias Loom.Terminal.Layout

  # GET /api/layout — the saved layout, reconciled against live sessions so the
  # client never renders a pane whose shell has already exited.
  def show(conn, _params) do
    json(conn, reconcile(Layout.get()))
  end

  # PUT /api/layout — client is the source of truth for arrangement.
  def update(conn, params) do
    :ok = Layout.put(params)
    json(conn, reconcile(Layout.get()))
  end

  # Drop pane references to dead sessions and any tab left with no panes.
  defp reconcile(%{tabs: tabs, active_tab: active}) do
    live_tabs =
      tabs
      |> Enum.map(fn tab ->
        %{id: tab.id, panes: Enum.filter(tab.panes, &Terminal.exists?/1)}
      end)
      |> Enum.reject(&(&1.panes == []))

    active =
      if Enum.any?(live_tabs, &(&1.id == active)),
        do: active,
        else: live_tabs |> List.first() |> then(&(&1 && &1.id))

    %{
      tabs: Enum.map(live_tabs, &%{id: &1.id, panes: &1.panes}),
      active_tab: active
    }
  end
end
