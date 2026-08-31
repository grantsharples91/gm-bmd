defmodule GmBmd.Bridge.Synth do
  @moduledoc """
  Turns a month bridge into a plausible daily accrual and billing schedule.

  Used by the seed generator for every month, and by the DB source for months
  the feed only carries as monthly totals (history before the daily feed
  started, and the forward months synthesised for target setting). The
  accrual is deterministic per club-month and reconciles exactly to the
  bridge, so every screen's maths still ties out.
  """

  alias GmBmd.Bridge
  alias GmBmd.Bridge.Shape

  @doc """
  Day rows for one club-month. `bridge` needs `opening`, `flows`,
  `defaults_raised` and `defaults_recovered`; `year`/`month` fix the calendar.
  """
  def day_rows(club_id, bridge, year, month) do
    dim = Date.days_in_month(Date.new!(year, month, 1))
    seed = "#{club_id}-#{Bridge.month_key(year, month)}"

    per_key =
      Map.new(Bridge.bridge_row_keys(), fn key ->
        values =
          if Bridge.fixed_row?(key) do
            # Fixed rows land in full on day 1 — known before the month starts.
            [Map.fetch!(bridge.flows, key) | List.duplicate(0, dim - 1)]
          else
            Shape.distribute(Map.fetch!(bridge.flows, key), weights(key, year, month, dim, seed))
          end

        {key, values}
      end)

    recurring_total =
      Map.get(bridge, :recurring_collected) ||
        round((bridge.opening - bridge.flows.duplicates) * 0.93)

    recurring = Shape.distribute(recurring_total, weights(:recurring, year, month, dim, seed))
    raised = Shape.distribute(bridge.defaults_raised, weights(:defaults, year, month, dim, seed))

    recovered =
      Shape.distribute(
        bridge.defaults_recovered,
        weights(:defaults_recovered, year, month, dim, seed)
      )

    unit = Bridge.unit_aed()

    for day <- 1..dim do
      i = day - 1
      flows = Map.new(per_key, fn {key, values} -> {key, Enum.at(values, i)} end)
      recurring_collected = Enum.at(recurring, i)
      day_recovered = Enum.at(recovered, i)

      revenue =
        recurring_collected * unit.recurring +
          flows.new_sales * unit.new_sale +
          flows.upfront * unit.upfront +
          (flows.prior_default_collections + flows.agency_collections + day_recovered) *
            unit.recovery -
          flows.refunds * unit.refund

      %{
        club_id: club_id,
        date: Date.new!(year, month, day),
        flows: flows,
        defaults_raised: Enum.at(raised, i),
        defaults_recovered: day_recovered,
        recurring_collected: recurring_collected,
        revenue_aed: revenue
      }
    end
  end

  @doc "A full month of billing runs for one club-month, shaped to the UAE week."
  def billing_runs(club_id, bridge, year, month) do
    dim = Date.days_in_month(Date.new!(year, month, 1))
    key = Bridge.month_key(year, month)
    base = round((bridge.opening - bridge.flows.duplicates) * 0.93)
    noise = Shape.noise_stream("runs-#{club_id}-#{key}", dim)

    weights =
      for day <- 1..dim do
        date = Date.new!(year, month, day)
        Shape.run_shape(day, Shape.dow(date), dim) * (0.88 + Enum.at(noise, day - 1) * 0.24)
      end

    due = Shape.distribute(base, weights)
    pct_noise = Shape.noise_stream("runpct-#{club_id}-#{key}", dim)

    for day <- 1..dim do
      %{
        club_id: club_id,
        month: key,
        day: day,
        date: Date.new!(year, month, day),
        members_due: Enum.at(due, day - 1),
        last_collected_pct: 0.9 + Enum.at(pct_noise, day - 1) * 0.06
      }
    end
  end

  defp weights(key, year, month, dim, seed), do: Shape.weights_for(key, year, month, dim, seed)
end
