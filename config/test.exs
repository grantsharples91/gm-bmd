import Config

config :gm_bmd, GmBmd.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "gm_bmd_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :gm_bmd, GmBmdWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test-only-secret-key-base-test-only-secret-key-base-test-only-secret-12",
  server: false

config :gm_bmd, :dev_identity, %{
  "x-thor-user-id" => "test-user",
  "x-thor-email" => "test@gymnation.com",
  "x-thor-groups" => "superuser",
  "x-thor-clubs" => "",
  "x-thor-perms" => "",
  "x-thor-locale" => "en",
  "x-thor-theme" => "light"
}

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
