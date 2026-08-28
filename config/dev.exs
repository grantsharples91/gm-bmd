import Config

config :gm_bmd, GmBmd.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "gm_bmd_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :gm_bmd, GmBmdWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev-only-secret-key-base-dev-only-secret-key-base-dev-only-secret-1234",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:gm_bmd, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:gm_bmd, ~w(--watch)]}
  ]

config :gm_bmd, GmBmdWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/gm_bmd_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

# Dev identity stub — the same x-thor-* header-reading code path runs everywhere.
config :gm_bmd, :dev_identity, %{
  "x-thor-user-id" => "dev-user",
  "x-thor-email" => "dev@gymnation.com",
  "x-thor-groups" => "superuser",
  "x-thor-clubs" => "",
  "x-thor-perms" => "",
  "x-thor-locale" => "en",
  "x-thor-theme" => "system"
}

config :gm_bmd, dev_routes: true

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, debug_heex_annotations: true, enable_expensive_runtime_checks: true
