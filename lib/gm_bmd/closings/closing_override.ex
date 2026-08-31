defmodule GmBmd.Closings.ClosingOverride do
  @moduledoc "A manager-set month-end closing (total transactions) for one club-month."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "closing_overrides" do
    field :month, :string
    field :club_id, :string
    field :value, :integer
    field :set_by, :string
    field :note, :string

    timestamps()
  end

  def changeset(override, attrs) do
    override
    |> cast(attrs, [:month, :club_id, :value, :set_by, :note])
    |> validate_required([:month, :club_id, :value])
    |> validate_number(:value, greater_than_or_equal_to: 0)
    |> unique_constraint([:month, :club_id])
  end
end
