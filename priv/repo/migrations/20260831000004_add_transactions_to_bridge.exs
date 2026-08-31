defmodule GmBmd.Repo.Migrations.AddTransactionsToBridge do
  use Ecto.Migration

  # The actual transaction count from THOR (Transaction_Count) — the month's
  # closing total, and per day the movement in it. Null = not supplied.
  def change do
    alter table(:bridge_months) do
      add :transactions, :integer
    end

    alter table(:bridge_days) do
      add :transactions, :integer
    end
  end
end
