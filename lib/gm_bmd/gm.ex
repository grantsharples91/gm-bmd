defmodule GmBmd.Gm do
  @moduledoc """
  GM membership-analysis maths — pure functions over the bridge data.
  EVERYTHING IS TRANSACTIONS. The monthly bridge is the single source of truth;
  revenue (AED) is derived and always secondary.
  """

  alias GmBmd.Bridge

  @all_clubs "all"
  # Retry rate assumption: share of failed payments auto-retried.
  @retry_rate 0.94
  # Fallback AED per transaction when a selection has no revenue yet.
  @avg_txn_aed 299

  def all_clubs, do: @all_clubs
  def retry_rate, do: @retry_rate
  def avg_txn_aed, do: @avg_txn_aed

  def club_ids(@all_clubs), do: Enum.map(Bridge.clubs(), & &1.id)
  def club_ids(club_id), do: [club_id]

  @doc "Rows for a month, optionally one club, optionally only up to a day (MTD)."
  def rows_for(month, club_id, through_day \\ nil) do
    Bridge.day_rows(month)
    |> Enum.filter(fn row ->
      (club_id == @all_clubs or row.club_id == club_id) and
        (through_day == nil or row.date.day <= through_day)
    end)
  end

  @doc "Totals for a list of day rows."
  def aggregate(rows) do
    zero = Bridge.zero_flows()

    acc =
      Enum.reduce(
        rows,
        %{
          flows: zero,
          defaults_raised: 0,
          defaults_recovered: 0,
          recurring_collected: 0,
          revenue: 0,
          transactions: 0,
          transactions_known: false
        },
        fn row, acc ->
          txn = Map.get(row, :transactions)

          %{
            flows: Map.new(acc.flows, fn {k, v} -> {k, v + Map.fetch!(row.flows, k)} end),
            defaults_raised: acc.defaults_raised + row.defaults_raised,
            defaults_recovered: acc.defaults_recovered + row.defaults_recovered,
            recurring_collected: acc.recurring_collected + row.recurring_collected,
            revenue: acc.revenue + row.revenue_aed,
            transactions: acc.transactions + (txn || 0),
            transactions_known: acc.transactions_known or txn != nil
          }
        end
      )

    outstanding = max(acc.defaults_raised - acc.defaults_recovered, 0)

    collected =
      acc.recurring_collected + acc.flows.new_sales + acc.flows.upfront +
        acc.flows.prior_default_collections + acc.flows.agency_collections +
        acc.defaults_recovered

    Map.merge(acc, %{
      outstanding: outstanding,
      recovery_pct:
        if(acc.defaults_raised > 0, do: acc.defaults_recovered / acc.defaults_raised, else: 0.0),
      collected_transactions: collected,
      yield: if(collected > 0, do: acc.revenue / collected, else: 0.0)
    })
  end

  @doc """
  Month-end closing for a selection — what the following month opens on.
  `value` is the sum of each club's closing (manager override where set,
  else the computed total); `computed` is the system figure; `overrides`
  lists the manager-set ones.
  """
  def closing_for(month, club_id) do
    bridges =
      club_id
      |> club_ids()
      |> Enum.map(&Bridge.bridge_for(&1, month))
      |> Enum.reject(&is_nil/1)

    overrides =
      bridges
      |> Enum.filter(&Map.get(&1, :closing_override))
      |> Enum.map(fn b -> Map.put(b.closing_override, :club_id, b.club_id) end)

    %{
      value: bridges |> Enum.map(&(Map.get(&1, :closing) || &1.total)) |> Enum.sum(),
      computed: bridges |> Enum.map(& &1.total) |> Enum.sum(),
      overrides: overrides,
      clubs: length(bridges)
    }
  end

  @doc "Opening transactions for a selection in a month (a stock — never pro-rated)."
  def opening_for(month, club_id) do
    club_id
    |> club_ids()
    |> Enum.map(fn id ->
      case Bridge.bridge_for(id, month) do
        nil -> 0
        bridge -> bridge.opening
      end
    end)
    |> Enum.sum()
  end

  def month_kind_of(month) do
    case Bridge.month_meta(month) do
      nil -> :actual
      meta -> meta.kind
    end
  end

  @reconcile_row %{
    key: :reconcile,
    label: "Still to run / unreconciled",
    short: "Still to run",
    sign: 1
  }

  def reconcile_row, do: @reconcile_row

  @doc """
  The bridge for a selection. `through_day` gives the MTD bridge; nil = full
  month. When the feed carries the actual transaction count, the total IS
  that count and a reconciling line closes the gap between the count and
  what the nine rows explain — mid-month that is mostly members whose
  billing day has not come yet; at month end it is movement the rows do not
  capture.
  """
  def bridge_snapshot(month, club_id, through_day \\ nil) do
    opening = opening_for(month, club_id)
    totals = aggregate(rows_for(month, club_id, through_day))

    {lines, projected} =
      Enum.map_reduce(Bridge.bridge_rows(), opening, fn row, running ->
        value = Map.fetch!(totals.flows, row.key)
        running = running + row.sign * value
        {Map.merge(row, %{value: value, fixed: Bridge.fixed_row?(row.key), running: running}), running}
      end)

    {lines, total} =
      if totals.transactions_known do
        actual = totals.transactions

        line =
          Map.merge(@reconcile_row, %{
            value: actual - projected,
            fixed: false,
            running: actual,
            reconcile: true
          })

        {lines ++ [line], actual}
      else
        {lines, projected}
      end

    %{
      month: month,
      kind: month_kind_of(month),
      opening: opening,
      lines: lines,
      flows: totals.flows,
      projected: projected,
      reconcile: total - projected,
      total: total,
      net_growth: total - opening
    }
  end

  # ----------------------------------------------------------- targets & pace

  @doc "Finance-sheet targets for a selection (revenue target lives only here)."
  def finance_targets_for(club_id) do
    targets = Bridge.finance_targets()

    list =
      if club_id == @all_clubs,
        do: targets,
        else: Enum.filter(targets, &(&1.club_id == club_id))

    %{
      new_sales_target: list |> Enum.map(& &1.new_sales_target) |> Enum.sum(),
      upfront_target: list |> Enum.map(& &1.upfront_target) |> Enum.sum(),
      total_target: list |> Enum.map(& &1.total_target) |> Enum.sum(),
      revenue_target: list |> Enum.map(& &1.revenue_target) |> Enum.sum()
    }
  end

  def rag_of(_actual, expected) when expected <= 0, do: :green

  def rag_of(actual, expected) do
    ratio = actual / expected

    cond do
      ratio >= 0.98 -> :green
      ratio >= 0.9 -> :amber
      true -> :red
    end
  end

  @doc "Straight-line expected-by-today: target × days elapsed ÷ days in month."
  def expected_by_today(target, month) do
    meta = Bridge.month_meta(month) || hd(Bridge.months())
    total = Bridge.days_in_month(meta)

    elapsed =
      if month == Bridge.current_month_key(),
        do: min(Bridge.today_day(), total),
        else: total

    %{expected: target * elapsed / total, elapsed: elapsed, total: total}
  end

  @doc "Compare mode: vs last month same day, or vs the straight-line target pace."
  def delta_for(actual, opts) do
    base =
      case opts.mode do
        :last_month -> opts.last_month
        :target -> expected_by_today(opts.target, opts.month).expected
      end

    pct = if base != 0, do: (actual - base) / base, else: 0.0
    invert = Map.get(opts, :invert, false)
    good = if invert, do: pct <= 0, else: pct >= 0

    rag =
      cond do
        abs(pct) < 0.03 -> :amber
        good -> :green
        true -> :red
      end

    sign = if pct > 0, do: "+", else: ""

    label_tail =
      if opts.mode == :last_month, do: "vs last month same day", else: "vs target pace"

    %{
      label: "#{sign}#{Float.round(pct * 100, 1)}% #{label_tail}",
      pct: pct,
      rag: rag
    }
  end

  @doc "Previous selectable month key relative to a selected month."
  def previous_month_of(month) do
    picker = Bridge.picker_months()
    idx = Enum.find_index(picker, &(&1.key == month)) || 0

    case Enum.at(picker, idx + 1) do
      nil -> List.last(picker).key
      meta -> meta.key
    end
  end

  # ------------------------------------------------------------------ outturn

  @doc """
  Raw outturn scaffold: MTD actuals plus a remaining figure per bridge row
  (run-rate for sales rows, plan for run-driven rows — `GmBmd.Outturn` replaces
  the run-driven remainders with the billing-schedule engine).
  """
  def outturn_for(club_id, sales_overrides \\ %{}, month, target_override \\ nil) do
    meta = Bridge.month_meta(month) || hd(Bridge.months())
    days_total = Bridge.days_in_month(meta)
    current? = month == Bridge.current_month_key()
    days_elapsed = if current?, do: min(Bridge.today_day(), days_total), else: days_total
    days_remaining = days_total - days_elapsed

    mtd = bridge_snapshot(month, club_id, days_elapsed)
    full = bridge_snapshot(month, club_id)
    prev_month = previous_month_of(month)
    prev = bridge_snapshot(prev_month, club_id)

    rows =
      Enum.map(Bridge.bridge_rows(), fn row ->
        mtd_value = Map.fetch!(mtd.flows, row.key)
        fixed = Bridge.fixed_row?(row.key)

        if fixed do
          %{
            key: row.key,
            label: row.label,
            short: row.short,
            sign: row.sign,
            fixed: true,
            mtd: mtd_value,
            run_rate: 0,
            remaining: 0,
            forecast: mtd_value,
            last_month: Map.fetch!(prev.flows, row.key)
          }
        else
          plan_remaining = max(Map.fetch!(full.flows, row.key) - mtd_value, 0)

          run_rate =
            if row.key in [:new_sales, :upfront],
              do: round(mtd_value / max(days_elapsed, 1) * days_remaining),
              else: plan_remaining

          remaining = max(round(Map.get(sales_overrides, row.key) || run_rate), 0)

          %{
            key: row.key,
            label: row.label,
            short: row.short,
            sign: row.sign,
            fixed: false,
            mtd: mtd_value,
            run_rate: run_rate,
            remaining: remaining,
            forecast: mtd_value + remaining,
            last_month: Map.fetch!(prev.flows, row.key)
          }
        end
      end)

    # Outturn = where we are (the MTD total) plus what is still to come. Equal
    # to opening + signed forecasts when the rows explain the count fully.
    base = Enum.reduce(rows, mtd.total, fn r, acc -> acc + r.sign * r.remaining end)
    remaining_gross = rows |> Enum.map(& &1.remaining) |> Enum.sum()

    legacy = finance_targets_for(club_id)

    targets =
      case target_override do
        nil -> legacy
        o -> %{legacy | total_target: o.total_target, new_sales_target: o.new_sales_target}
      end

    mtd_agg = aggregate(rows_for(month, club_id, days_elapsed))
    full_agg = aggregate(rows_for(month, club_id))

    ran = mtd_agg.recurring_collected
    run_full = full_agg.recurring_collected
    runs_left = Enum.filter(1..days_total, &(&1 > days_elapsed))

    scheduled_left =
      Bridge.billing_runs(month)
      |> Enum.filter(fn r ->
        r.day > days_elapsed and (club_id == @all_clubs or r.club_id == club_id)
      end)
      |> Enum.map(& &1.members_due)
      |> Enum.sum()

    forecast_to_run =
      max(round(if(scheduled_left > 0, do: scheduled_left, else: run_full - ran)), 0)

    runs_done = days_elapsed
    new_sales_row = Enum.find(rows, &(&1.key == :new_sales))

    %{
      month: month,
      opening: mtd.opening,
      rows: rows,
      mtd_total: mtd.total,
      base: base,
      best: round(base + remaining_gross * 0.05),
      worst: round(base - remaining_gross * 0.06),
      net_growth: base - mtd.opening,
      total_target: targets.total_target,
      new_sales_mtd: new_sales_row.mtd,
      new_sales_forecast: new_sales_row.forecast,
      new_sales_target: targets.new_sales_target,
      last_month_total: prev.total,
      last_month_net_growth: prev.net_growth,
      days_elapsed: days_elapsed,
      days_remaining: days_remaining,
      days_total: days_total,
      billing_runs_left: runs_left,
      billing_runs_done: runs_done,
      ran: round(ran),
      forecast_to_run: forecast_to_run,
      total_to_run: round(ran) + forecast_to_run,
      per_run_average: if(runs_done > 0, do: round(ran / runs_done), else: 0),
      avg_due_left:
        if(runs_left != [], do: round(forecast_to_run / length(runs_left)), else: 0),
      revenue_mtd: mtd_agg.revenue,
      revenue_forecast: mtd_agg.revenue + max(full_agg.revenue - mtd_agg.revenue, 0),
      revenue_target: targets.revenue_target
    }
  end

  @doc """
  Cumulative by day — new membership sales actual vs forecast vs straight-line
  target, with the AED equivalents alongside.
  """
  def cumulative_series(month, club_id, targets \\ nil) do
    meta = Bridge.month_meta(month) || hd(Bridge.months())
    total = Bridge.days_in_month(meta)
    targets = targets || finance_targets_for(club_id)
    rows = rows_for(month, club_id)
    current? = month == Bridge.current_month_key()
    today = Bridge.today_day()

    by_day =
      Enum.reduce(rows, %{}, fn row, acc ->
        Map.update(
          acc,
          row.date.day,
          {row.flows.new_sales, row.revenue_aed},
          fn {s, a} -> {s + row.flows.new_sales, a + row.revenue_aed} end
        )
      end)

    {points, _} =
      Enum.map_reduce(1..total, {0, 0}, fn day, {run_sales, run_aed} ->
        {s, a} = Map.get(by_day, day, {0, 0})
        run_sales = run_sales + s
        run_aed = run_aed + a
        actual_day? = not current? or day <= today

        point = %{
          day: day,
          actual: if(actual_day?, do: run_sales),
          forecast: run_sales,
          target: round(targets.new_sales_target * day / total),
          actual_aed: if(actual_day?, do: round(run_aed)),
          target_aed: round(targets.revenue_target * day / total)
        }

        {point, {run_sales, run_aed}}
      end)

    points
  end

  # ----------------------------------------------------------------- defaults

  @doc "Defaults mini-funnel, in transactions: due → failed → retried → recovered → outstanding."
  def defaults_funnel(t) do
    [
      %{key: :due, label: "Due this month", count: t.recurring_collected + t.defaults_raised},
      %{key: :failed, label: "Failed (defaulted)", count: t.defaults_raised},
      %{key: :retried, label: "Retried", count: round(t.defaults_raised * @retry_rate)},
      %{key: :recovered, label: "Recovered", count: t.defaults_recovered},
      %{key: :outstanding, label: "Outstanding", count: t.outstanding}
    ]
  end

  @doc "Total defaulted / collected / outstanding — count, share and AED."
  def defaults_breakdown(t) do
    per = if t.yield > 0, do: t.yield, else: @avg_txn_aed
    share = fn n -> if t.defaults_raised > 0, do: n / t.defaults_raised, else: 0.0 end

    %{
      raised: t.defaults_raised,
      recovered: t.defaults_recovered,
      outstanding: t.outstanding,
      recovered_pct: share.(t.defaults_recovered),
      outstanding_pct: share.(t.outstanding),
      aed: %{
        raised: t.defaults_raised * per,
        recovered: t.defaults_recovered * per,
        outstanding: t.outstanding * per
      }
    }
  end
end
