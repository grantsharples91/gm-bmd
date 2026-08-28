defmodule GmBmd.Outturn do
  @moduledoc """
  OUTTURN — one source of truth for the month-end forecast.

  The billing schedule is the engine. Everything that lands on a billing run is
  computed from TRANSACTIONS TO RUN × an observed rate; new sales and upfronts
  stay sales-driven (MTD run-rate over the days left, overridable by the GM).
  Every observed rate is derived from MTD actuals and is the editable
  assumption; the "remaining" number is then read-only for run-driven rows.
  """

  alias GmBmd.Gm

  @run_driven [:prior_default_collections, :agency_collections, :cancel_within, :defaults, :refunds]

  @assumption_meta %{
    default_rate_pct: %{label: "Default rate", kind: :pct, step: 0.05, max: 25},
    collect_rate_pct: %{label: "Within-month collect rate", kind: :pct, step: 1, max: 100},
    recovery_per_run: %{label: "Recoveries per day", kind: :per_run, step: 5, max: 100_000},
    agency_per_run: %{label: "Agency per day", kind: :per_run, step: 1, max: 100_000},
    refund_rate_pct: %{label: "Refund rate", kind: :pct, step: 0.05, max: 25},
    cancel_within_rate_pct: %{label: "Cancellation rate", kind: :pct, step: 0.05, max: 25}
  }

  def run_driven?(key), do: key in @run_driven
  def assumption_meta, do: @assumption_meta

  defp rate(a, b) when b > 0, do: a / b * 100
  defp rate(_a, _b), do: 0.0

  @doc "Rates observed so far this month — what the assumption inputs start from."
  def observed_rates(month, club_id, days_elapsed, runs_done) do
    t = Gm.aggregate(Gm.rows_for(month, club_id, days_elapsed))
    ran = max(t.recurring_collected, 1)

    %{
      default_rate_pct: rate(t.defaults_raised, ran),
      collect_rate_pct: rate(t.defaults_recovered, max(t.defaults_raised, 1)),
      recovery_per_run:
        if(runs_done > 0, do: round(t.flows.prior_default_collections / runs_done), else: 0),
      agency_per_run:
        if(runs_done > 0, do: round(t.flows.agency_collections / runs_done), else: 0),
      refund_rate_pct: rate(t.flows.refunds, ran),
      cancel_within_rate_pct: rate(t.flows.cancel_within, ran)
    }
  end

  @doc """
  Build the whole outturn: run-driven rows computed from the billing schedule,
  sales-driven rows from the MTD run-rate (or the GM's override).
  """
  def build(club_id, month, target_override \\ nil, assumption_overrides \\ %{}, sales_overrides \\ %{}) do
    raw = Gm.outturn_for(club_id, sales_overrides, month, target_override)
    runs_left = length(raw.billing_runs_left)
    mtd_agg = Gm.aggregate(Gm.rows_for(month, club_id, raw.days_elapsed))
    observed = observed_rates(month, club_id, raw.days_elapsed, raw.billing_runs_done)
    assumptions = Map.merge(observed, assumption_overrides)

    edited =
      assumption_overrides
      |> Map.keys()
      |> Enum.filter(fn k ->
        abs(Map.fetch!(assumption_overrides, k) - Map.fetch!(observed, k)) > 0.0001
      end)

    to_run = raw.forecast_to_run
    rem_raised = round(to_run * assumptions.default_rate_pct / 100)
    rem_collected = round(rem_raised * assumptions.collect_rate_pct / 100)
    rem_outstanding = max(rem_raised - rem_collected, 0)
    rem_recoveries = round(runs_left * assumptions.recovery_per_run)
    rem_agency = round(runs_left * assumptions.agency_per_run)
    rem_refunds = round(to_run * assumptions.refund_rate_pct / 100)
    rem_cancel = round(to_run * assumptions.cancel_within_rate_pct / 100)

    run_row = fn key ->
      case key do
        :defaults ->
          %{
            remaining: rem_outstanding,
            formula: "#{n(to_run)} × #{p(assumptions.default_rate_pct)} = #{n(rem_raised)}",
            sub:
              "− #{n(rem_collected)} collected (#{p(assumptions.collect_rate_pct)}) = #{n(rem_outstanding)} outstanding",
            rate: :default_rate_pct
          }

        :prior_default_collections ->
          %{
            remaining: rem_recoveries,
            formula: "#{runs_left} daily runs × #{n(assumptions.recovery_per_run)} = #{n(rem_recoveries)}",
            sub: if(runs_left > 0, do: "a run every day to the #{raw.days_total}th", else: "no runs left"),
            rate: :recovery_per_run
          }

        :agency_collections ->
          %{
            remaining: rem_agency,
            formula: "#{runs_left} daily runs × #{n(assumptions.agency_per_run)} = #{n(rem_agency)}",
            sub: nil,
            rate: :agency_per_run
          }

        :refunds ->
          %{
            remaining: rem_refunds,
            formula: "#{n(to_run)} × #{p(assumptions.refund_rate_pct)} = #{n(rem_refunds)}",
            sub: nil,
            rate: :refund_rate_pct
          }

        :cancel_within ->
          %{
            remaining: rem_cancel,
            formula: "#{n(to_run)} × #{p(assumptions.cancel_within_rate_pct)} = #{n(rem_cancel)}",
            sub: nil,
            rate: :cancel_within_rate_pct
          }
      end
    end

    rows =
      Enum.map(raw.rows, fn r ->
        cond do
          r.fixed ->
            Map.merge(r, %{
              driver: :fixed,
              formula: nil,
              formula_sub: "fixed on day 1 — forecast = actual",
              rate: nil
            })

          not run_driven?(r.key) ->
            per_day = r.mtd / max(raw.days_elapsed, 1)

            Map.merge(r, %{
              driver: :sales,
              formula:
                "#{:erlang.float_to_binary(per_day, decimals: 1)}/day × #{raw.days_remaining} days = #{n(r.run_rate)}",
              formula_sub:
                if(Map.get(sales_overrides, r.key), do: "GM override #{n(r.remaining)}"),
              rate: nil
            })

          true ->
            rd = run_row.(r.key)

            Map.merge(r, %{
              remaining: rd.remaining,
              forecast: r.mtd + rd.remaining,
              driver: :run,
              formula: rd.formula,
              formula_sub: rd.sub,
              rate: %{key: rd.rate, value: Map.fetch!(assumptions, rd.rate)}
            })
        end
      end)

    base = Enum.reduce(rows, raw.opening, fn r, acc -> acc + r.sign * r.forecast end)

    sales_remaining =
      rows |> Enum.filter(&(&1.driver == :sales)) |> Enum.map(& &1.remaining) |> Enum.sum()

    defaults_swing = round(rem_outstanding * 0.25)
    sales_swing = round(sales_remaining * 0.05)

    get = fn key -> Enum.find(rows, &(&1.key == key)) end

    waterfall = [
      %{key: :mtd, label: "MTD position", value: raw.mtd_total, kind: :start, run_driven: false, note: "day #{raw.days_elapsed} of #{raw.days_total}"},
      %{key: :new_sales, label: "Remaining sales", value: get.(:new_sales).remaining, kind: :add, run_driven: false, note: "sales-driven"},
      %{key: :upfront, label: "Remaining upfronts", value: get.(:upfront).remaining, kind: :add, run_driven: false, note: "sales-driven"},
      %{key: :recoveries, label: "Remaining prior recoveries", value: rem_recoveries + rem_agency, kind: :add, run_driven: true, note: "#{runs_left} daily runs × #{n(assumptions.recovery_per_run + assumptions.agency_per_run)}"},
      %{key: :defaults, label: "Forecast defaults not recovered", value: rem_outstanding, kind: :sub, run_driven: true, note: "#{n(to_run)} to run × #{p(assumptions.default_rate_pct)}"},
      %{key: :refunds, label: "Forecast refunds", value: rem_refunds, kind: :sub, run_driven: true, note: "#{n(to_run)} to run × #{p(assumptions.refund_rate_pct)}"},
      %{key: :cancel_within, label: "Forecast cancellations in month", value: rem_cancel, kind: :sub, run_driven: true, note: "#{n(to_run)} to run × #{p(assumptions.cancel_within_rate_pct)}"},
      %{key: :outturn, label: "Outturn", value: base, kind: :end, run_driven: false, note: "vs target #{n(raw.total_target)}"}
    ]

    forecast_by_row = Map.new(rows, fn r -> {r.key, r.forecast} end)

    Map.merge(raw, %{
      rows: rows,
      base: base,
      best: base + sales_swing + defaults_swing,
      worst: base - sales_swing - defaults_swing,
      net_growth: base - raw.opening,
      new_sales_forecast: get.(:new_sales).forecast,
      assumptions: assumptions,
      observed: observed,
      edited: edited,
      waterfall: waterfall,
      remaining_defaults_raised: rem_raised,
      remaining_defaults_collected: rem_collected,
      mtd_defaults_raised: mtd_agg.defaults_raised,
      mtd_defaults_collected: mtd_agg.defaults_recovered,
      forecast_by_row: forecast_by_row
    })
  end

  @doc """
  EVERY month-end KPI total, run-driven and sales-driven, from this one model —
  so the Daily page closes on exactly the same number as the dashboard.
  """
  def daily_month_end_totals(model) do
    %{
      prior_recoveries:
        model.forecast_by_row.prior_default_collections + model.forecast_by_row.agency_collections,
      defaults_raised: model.mtd_defaults_raised + model.remaining_defaults_raised,
      defaults_collected: model.mtd_defaults_collected + model.remaining_defaults_collected,
      cancel_within: model.forecast_by_row.cancel_within,
      refunds: model.forecast_by_row.refunds,
      new_sales: model.forecast_by_row.new_sales,
      upfront: model.forecast_by_row.upfront
    }
  end

  @doc """
  Defaults reconciliation for the month-end position calculator. The defaults
  input is the TOTAL outstanding balance expected at month end; only the
  difference from today's outstanding is deducted from the position.
  """
  def defaults_forecast(model) do
    row = Enum.find(model.rows, &(&1.key == :defaults))

    %{
      mtd_outstanding: row.mtd,
      remaining_not_recovered: row.remaining,
      system_forecast: row.mtd + row.remaining,
      last_month_closed: row.last_month
    }
  end

  defp n(value), do: GmBmd.Format.num(value)
  defp p(value), do: "#{:erlang.float_to_binary(value / 1, decimals: 2)}%"
end
