defmodule GmBmd.Targets.Target do
  @moduledoc "One cell of the T2 target grid: month × club × KPI."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @kpis ~w(total new_sales defaults prior_recoveries upfront)

  schema "targets" do
    field :month, :string
    field :club_id, :string
    field :kpi, :string
    field :t2_value, :integer

    timestamps()
  end

  def kpis, do: @kpis

  def changeset(target, attrs) do
    target
    |> cast(attrs, [:month, :club_id, :kpi, :t2_value])
    |> validate_required([:month, :club_id, :kpi, :t2_value])
    |> validate_inclusion(:kpi, @kpis)
    |> validate_number(:t2_value, greater_than_or_equal_to: 0)
    |> unique_constraint([:month, :club_id, :kpi])
  end
end
