defmodule GmBmdWeb.FrameHeaders do
  @moduledoc """
  CSP for a framed THOR3 action: allow the shell origins in `frame-ancestors`
  (the default `put_secure_browser_headers` blocks the shell and the tab shows
  \"refused to connect\") and drop `x-frame-options`, which cannot express an
  origin allow-list.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    shell_origins = Application.get_env(:gm_bmd, :shell_origins, []) |> Enum.join(" ")

    conn
    |> delete_resp_header("x-frame-options")
    |> put_resp_header(
      "content-security-policy",
      "frame-ancestors 'self' #{shell_origins}"
    )
  end
end
