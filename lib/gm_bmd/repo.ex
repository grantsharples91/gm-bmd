defmodule GmBmd.Repo do
  use Ecto.Repo,
    otp_app: :gm_bmd,
    adapter: Ecto.Adapters.Postgres
end
