defmodule LoomWeb.ChannelCase do
  @moduledoc "Test case for Phoenix channels."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import LoomWeb.ChannelCase

      @endpoint LoomWeb.Endpoint
    end
  end
end
