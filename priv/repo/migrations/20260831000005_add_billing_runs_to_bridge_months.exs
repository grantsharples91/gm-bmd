defmodule GmBmd.Repo.Migrations.AddBillingRunsToBridgeMonths do
  use Ecto.Migration

  # The billing-run metric from THOR's Collections section, month to date:
  # attempts = first-time successes + first-time defaults (the identity the
  # dashboard enforces); forecast_thor is THOR's own "Forecast" figure, kept
  # for the variance. Null = not supplied.
  def change do
    alter table(:bridge_months) do
      add :runs_forecast_thor, :integer
      add :runs_success, :integer
      add :runs_defaults, :integer
      add :runs_wmr, :integer
      add :runs_pmr, :integer
      add :runs_mccm, :integer
    end
  end
end
