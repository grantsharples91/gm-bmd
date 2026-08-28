defmodule GmBmd.Targets.GmForecast do
  @moduledoc "A GM's saved month-end position forecast for a month × club selection."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gm_forecasts" do
    field :month, :string
    field :club_id, :string
    field :value, :integer
    field :saved_by, :string

    timestamps()
  end

  def changeset(forecast, attrs) do
    forecast
    |> cast(attrs, [:month, :club_id, :value, :saved_by])
    |> validate_required([:month, :club_id, :value])
    |> unique_constraint([:month, :club_id])
  end
end
