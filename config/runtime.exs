import Config

if System.get_env("PHX_SERVER") do
  config :gm_bmd, GmBmdWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      """

  # PgBouncer transaction pooling — see the Allfather database guide.
  config :gm_bmd, GmBmd.Repo,
    url: database_url,
    pool_size: 8,
    prepare: :unnamed,
    migration_lock: false,
    socket_options: []

  config :gm_bmd, migrate_on_boot: true

  # Bearer token for POST /api/ingest (the THOR feed sync). Unset = disabled.
  config :gm_bmd, ingest_token: System.get_env("INGEST_TOKEN")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      """

  host = System.get_env("PHX_HOST") || "gm-bmd.act.gymnation.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :gm_bmd, GmBmdWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base

  shell_origins =
    case System.get_env("SHELL_ORIGINS") do
      nil -> ["https://thor.gymnation.com", "https://staging-thor.gymnation.com"]
      raw -> raw |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end

  config :gm_bmd, :shell_origins, shell_origins
end
