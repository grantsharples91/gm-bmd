defmodule GmBmd.Repo.Migrations.CreateBridgeTables do
  use Ecto.Migration

  # The THOR feed lands here: one row per club, per club-month bridge, per
  # club-day accrual and per club-day billing run. `bridge_meta` carries the
  # feed's as-of date and provenance. Everything is upserted by the ingest
  # endpoint (`POST /api/ingest`) or the boot-time snapshot loader.
  def change do
    create table(:bridge_clubs, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :city, :string, null: false, default: ""
      add :sort, :integer, null: false, default: 0
    end

    create table(:bridge_months) do
      add :club_id, :string, null: false
      add :month, :string, null: false
      add :kind, :string, null: false, default: "actual"
      add :opening, :integer, null: false, default: 0
      add :flows, :map, null: false, default: %{}
      add :defaults_raised, :integer, null: false, default: 0
      add :defaults_recovered, :integer, null: false, default: 0
      add :total, :integer, null: false, default: 0
      add :net_growth, :integer, null: false, default: 0
      add :revenue_aed, :float, null: false, default: 0.0
      add :recurring_collected, :integer, null: false, default: 0
    end

    create unique_index(:bridge_months, [:club_id, :month])

    create table(:bridge_days) do
      add :club_id, :string, null: false
      add :date, :date, null: false
      add :flows, :map, null: false, default: %{}
      add :defaults_raised, :integer, null: false, default: 0
      add :defaults_recovered, :integer, null: false, default: 0
      add :recurring_collected, :integer, null: false, default: 0
      add :revenue_aed, :bigint, null: false, default: 0
    end

    create unique_index(:bridge_days, [:club_id, :date])
    create index(:bridge_days, [:date])

    create table(:billing_runs) do
      add :club_id, :string, null: false
      add :date, :date, null: false
      add :members_due, :integer, null: false, default: 0
      add :last_collected_pct, :float, null: false, default: 0.0
    end

    create unique_index(:billing_runs, [:club_id, :date])

    create table(:bridge_meta, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text
    end
  end
end
