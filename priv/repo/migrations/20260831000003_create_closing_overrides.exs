defmodule GmBmd.Repo.Migrations.CreateClosingOverrides do
  use Ecto.Migration

  # A site manager's month-end closing for one club-month. When set, it
  # replaces the computed total as the opening of the following month.
  def change do
    create table(:closing_overrides, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :month, :string, null: false
      add :club_id, :string, null: false
      add :value, :integer, null: false
      add :set_by, :string
      add :note, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:closing_overrides, [:month, :club_id])
  end
end
