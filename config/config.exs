import Config

config :gm_bmd,
  ecto_repos: [GmBmd.Repo],
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true],
  migrate_on_boot: false

config :gm_bmd, GmBmdWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: GmBmdWeb.ErrorHTML, json: GmBmdWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: GmBmd.PubSub,
  live_view: [signing_salt: "gmbmdlv1"]

# THOR3 shell origins allowed to frame this action (see runtime.exs for prod).
config :gm_bmd, :shell_origins, [
  "https://thor.gymnation.com",
  "https://staging-thor.gymnation.com"
]

config :esbuild,
  version: "0.25.4",
  gm_bmd: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "4.1.7",
  gm_bmd: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :gm_bmd, GmBmdWeb.Gettext, default_locale: "en", locales: ~w(en ar)

import_config "#{config_env()}.exs"
