defmodule GmBmdWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :gm_bmd

  # Framed by the THOR3 shell (a different origin): the cookie must be
  # SameSite=None; Secure or it is never sent back from the iframe.
  @session_options [
    store: :cookie,
    key: "_gm_bmd_key",
    signing_salt: "gmbmdsalt",
    same_site: "None",
    secure: true
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :gm_bmd,
    gzip: false,
    only: GmBmdWeb.static_paths()

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :gm_bmd
  end

  plug Plug.RequestId

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    # The THOR feed payload is a few MB for a full reload.
    length: 50_000_000,
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug GmBmdWeb.Router
end
