defmodule GmBmd.Repo.Migrations.CreateTargets do
  use Ecto.Migration

  def change do
    create table(:targets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :month, :string, null: false
      add :club_id, :string, null: false
      add :kpi, :string, null: false
      add :t2_value, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:targets, [:month, :club_id, :kpi])
  end
end
