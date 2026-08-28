defmodule GmBmd.Targets.TargetState do
  @moduledoc "Per-club-per-month approval state for the T2 target grid."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "target_states" do
    field :month, :string
    field :club_id, :string
    field :status, :string, default: "draft"
    field :approved_by, :string
    field :approved_at, :utc_datetime_usec
    field :unlock_reason, :string
    field :unlocked_by, :string

    timestamps()
  end

  def changeset(state, attrs) do
    state
    |> cast(attrs, [:month, :club_id, :status, :approved_by, :approved_at, :unlock_reason, :unlocked_by])
    |> validate_required([:month, :club_id, :status])
    |> validate_inclusion(:status, ~w(draft approved))
    |> unique_constraint([:month, :club_id])
  end
end
