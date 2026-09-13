defmodule LongxWeb.ChannelCase do
  @moduledoc """
  Test case for channels: `Phoenix.ChannelTest` against `LongxWeb.Endpoint`,
  with the DB sandbox (channels relay project rows).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import LongxWeb.ChannelCase

      @endpoint LongxWeb.Endpoint
    end
  end

  setup tags do
    Longx.DataCase.setup_sandbox(tags)
    :ok
  end
end
