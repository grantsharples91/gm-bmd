defmodule GmBmd.Repo.Migrations.CreateGmForecasts do
  use Ecto.Migration

  def change do
    create table(:gm_forecasts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :month, :string, null: false
      add :club_id, :string, null: false
      add :value, :integer, null: false
      add :saved_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gm_forecasts, [:month, :club_id])
  end
end
