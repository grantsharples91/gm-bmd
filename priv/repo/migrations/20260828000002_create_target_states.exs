defmodule GmBmd.Repo.Migrations.CreateTargetStates do
  use Ecto.Migration

  def change do
    create table(:target_states, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :month, :string, null: false
      add :club_id, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :approved_by, :string
      add :approved_at, :utc_datetime_usec
      add :unlock_reason, :string
      add :unlocked_by, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:target_states, [:month, :club_id])
  end
end
