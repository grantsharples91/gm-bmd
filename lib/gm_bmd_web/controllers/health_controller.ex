defmodule GmBmdWeb.HealthController do
  use GmBmdWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
