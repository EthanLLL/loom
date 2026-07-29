defmodule LoomWeb.PageController do
  use LoomWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
