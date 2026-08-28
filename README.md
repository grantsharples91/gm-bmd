# GM Business Management Dashboard (`gm-bmd`)

THOR3 action serving the GM membership-analysis dashboard at
**https://gm-bmd.act.gymnation.com** (behind THOR3 login). Elixir / Phoenix
LiveView / Postgres, built and deployed through Allfather.

## What it does

EVERYTHING IS TRANSACTIONS — the monthly membership-analysis bridge is the
single source of truth; revenue (AED) is derived and always secondary.

| Screen | Path | What it shows |
|---|---|---|
| Dashboard | `/` | Five MTD hero cards, plain-English verdict, needs-attention exceptions, yesterday + billing runs, tabbed bridge / by-club / position / revenue / outturn / activity |
| Daily | `/daily` | Day-by-day forecast vs actual per KPI, reconciled to the outturn close |
| Outturn | `/outturn` | Month-end position calculator — system forecast prefills, GM edits, save-as-my-forecast |
| Revenue | `/revenue` | Revenue & yield by stream and by club |
| Targets | `/targets` | Per-club T2 target grid with per-club approval, unlock-with-reason and history |

## Data

The bridge data is **seeded placeholder data** (`GmBmd.Bridge.Seeds`) —
deterministic, finance-sheet-shaped, five clubs, Jun–Dec 2026. The real feed
plugs in by implementing the six-callback `GmBmd.Bridge.Source` behaviour over
the production tables and setting:

```elixir
config :gm_bmd, :bridge_source, GmBmd.Bridge.DB
```

No screen code changes. Targets, approvals and GM forecasts are already real:
they live in this action's Postgres (`targets`, `target_states`,
`gm_forecasts`), seeded on first boot (prev + current month approved, next
month draft).

## Development

```sh
docker compose up -d postgres
mix setup
mix phx.server        # http://localhost:4000 (dev identity stub injects x-thor-* headers)
```

Verification gate: `mix compile --warnings-as-errors && mix format --check-formatted && mix test`.

## Deploy

Push to `main` (or any branch) → `ci.yml` compiles, tests and docker-builds.
Push to `prod` → `deploy-prod.yml` builds `linux/amd64`, pushes to the
Allfather registry and rolls out. Requires the `AF_API_KEY` repo secret.
Rollback = revert in git and push.

## THOR3 integration notes

- Identity arrives as trusted `x-thor-*` headers (auth lives at the ingress —
  no login page here). The dev stub in `config/dev.exs` injects the same
  headers locally.
- CSP `frame-ancestors` allows the shell origins; the session cookie is
  `SameSite=None; Secure`; no `force_ssl` (TLS terminates at the ingress).
- Theme/language: boot script reads the `#thor.theme` fragment before first
  paint, then follows `thor.settings` / `thor.settings.changed` postMessages;
  `thor.nav.state` is reported on every route change.
- Migrations run on boot (`Ecto.Migrator` in the supervision tree), PgBouncer
  transaction-pooling rules applied (`pool_size: 8`, `prepare: :unnamed`,
  `migration_lock: false`).
- Health probe: `GET /healthz`.
