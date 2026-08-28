import Config

# TLS terminates at the ingress — no force_ssl here (a redirect inside the app
# would loop; see the Allfather build guide).
config :gm_bmd, GmBmdWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info
