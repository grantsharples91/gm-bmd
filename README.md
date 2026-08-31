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

The dashboard reads the **THOR feed** through `GmBmd.Bridge.DB`: all 36 clubs,
one bridge row per club-month (Mar 2026 onwards), day rows and billing runs
for the months the feed covers by day. It lives in this action's Postgres
(`bridge_clubs`, `bridge_months`, `bridge_days`, `billing_runs`,
`bridge_meta`) and is filled two ways:

* **Boot-time bootstrap** — when the tables are empty, `GmBmd.Bridge.Loader`
  loads `priv/bridge/thor_snapshot.json` (a snapshot of the THOR Executive
  Forecast MTD summary, Telr feed). It never overwrites a feed already loaded.
* **`POST /api/ingest`** — the sync contract for the platform. Bearer-token
  authenticated (`INGEST_TOKEN` in the action environment; disabled when
  unset), takes the JSON shape documented in `GmBmd.Bridge.Ingest`, upserts
  on club-month / club-day, so a daily job can send just the current month.
  `GET /api/ingest/status` shows what is loaded and the as-of date.

The header badge (`THOR · data to 30 Aug`) shows the feed's as-of date; MTD
maths never runs past it, and the dashboard stays on the last month with
data until the next sync. Months the feed only carries as totals get a
synthesised daily accrual (`GmBmd.Bridge.Synth`) that reconciles exactly to
the bridge, and three forward months are synthesised (flows held at the last
full month) so targets can be set ahead.

Openings chain: every month opens on the prior month's closing. The system
computes each closing from the bridge, and a site manager can override it
from the Membership bridge tab (single club selected) — the override becomes
the next month's opening, the overridden month shows both figures and who set
it (`closing_overrides`, `GmBmd.Closings`).

> The mapping from THOR's MTD metrics onto the nine bridge rows is
> provisional — the shape is right, the numbers are not yet signed off.

Tests run on `GmBmd.Bridge.Seeds` (deterministic placeholder data — five
clubs, Jun–Dec 2026); `test/gm_bmd_web/thor_feed_test.exs` swaps in the DB
source and renders every screen on the real snapshot. Targets, approvals and
GM forecasts live in `targets`, `target_states`, `gm_forecasts`, seeded on
first boot (prev + current month approved, next month draft).

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
