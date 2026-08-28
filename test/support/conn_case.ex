defmodule GmBmdWeb.ConnCase do
  @moduledoc """
  Conn/LiveView test case. LiveView processes are separate from the test
  process, so the SQL sandbox runs in shared mode for non-async tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint GmBmdWeb.Endpoint

      use GmBmdWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import GmBmdWeb.ConnCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(GmBmd.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
