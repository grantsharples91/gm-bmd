defmodule GmBmd.Daily do
  @moduledoc """
  DAILY TRANSACTIONS — day-by-day view of the month, on the transaction-count
  basis: each day's bar is the successful transactions that day (THOR's
  count when the feed carries it), stacked by what they were — recurring
  dues, new sales, upfronts, prior recoveries, defaults collected. Failed
  attempts, cancellations and refunds sit below the axis for context; they
  are not transactions. The running position is the MTD count, so it ties to
  the dashboard's MTD transactions to the unit.

  Forecasts for the days still to come spread (target − MTD actual) over the
  remaining days. Recurring dues and defaults raised follow the billing
  schedule — the members due to run on each day — so the forecast lands on
  billing-run days, not on a day-of-week curve; the sales-driven KPIs use a
  day-of-week weight. The run-driven KPIs take their month-end totals from
  `GmBmd.Outturn`, and recurring dues absorb the rest, so this page and the
  outturn always close on the same number.
  """

  alias GmBmd.Bridge
  alias GmBmd.Gm

  @daily_kpis [
    %{key: :recurring, label: "Recurring dues", short: "Recurring", sign: 1, colour: "#8DA3B8"},
    %{key: :new_sales, label: "New sales", short: "New sales", sign: 1, colour: "#022A3A"},
    %{key: :prior_recoveries, label: "Prior recoveries", short: "Prior rec.", sign: 1, colour: "#2F6E86"},
    %{key: :upfront, label: "Upfronts", short: "Upfronts", sign: 1, colour: "#F4CD00"},
    %{key: :defaults_raised, label: "Defaults raised", short: "Def. raised", sign: -1, colour: "#B91C1C"},
    %{key: :defaults_collected, label: "Defaults collected", short: "Def. coll.", sign: 0, colour: "#059669"},
    %{key: :cancel_within, label: "Cx within month", short: "Cx in-month", sign: -1, colour: "#E06666"},
    %{key: :refunds, label: "Refunds", short: "Refunds", sign: -1, colour: "#F3A6A6"}
  ]

  @kpi_keys Enum.map(@daily_kpis, & &1.key)

  # KPIs that only move when a billing run happens: their daily shape is the
  # billing schedule (members due that day), never a day-of-week curve.
  @run_scheduled [:recurring, :defaults_raised]

  @chart_positive [
    %{key: :recurring, label: "Recurring dues", colour: "#8DA3B8"},
    %{key: :new_sales, label: "New sales", colour: "#022A3A"},
    %{key: :prior_recoveries, label: "Prior recoveries", colour: "#2F6E86"},
    %{key: :upfront, label: "Upfronts", colour: "#F4CD00"},
    %{key: :defaults_collected, label: "Defaults collected", colour: "#059669"}
  ]
  @chart_negative [
    %{key: :defaults_outstanding, label: "Defaults outstanding", colour: "#B91C1C"},
    %{key: :cancel_within, label: "Cancellations in month", colour: "#E06666"},
    %{key: :refunds, label: "Refunds", colour: "#F3A6A6"}
  ]

  def daily_kpis, do: @daily_kpis
  def chart_positive, do: @chart_positive
  def chart_negative, do: @chart_negative

  defp zero_kpis do
    @kpi_keys |> Map.new(&{&1, 0}) |> Map.merge(%{defaults_outstanding: 0, net: 0, transactions: 0})
  end

  @doc """
  Transactions in a day: recurring dues + new sales + upfronts + prior
  recoveries + defaults collected. Failed attempts, cancellations and refunds
  are not transactions and do not move the count.
  """
  def net_of(k) do
    k.recurring + k.new_sales + k.prior_recoveries + k.upfront + k.defaults_collected
  end

  # Day-of-week + calendar weight for one KPI on one day (UAE trading pattern).
  defp weight_for(kpi, day, dow, dim) do
    run = GmBmd.Bridge.Shape.run_shape(day, dow, dim)

    case kpi do
      :new_sales ->
        week =
          case dow do
            :fri -> 0.6
            :sat -> 1.35
            :sun -> 1.1
            _ -> 1.0
          end

        week * if day > dim - 3, do: 1.15, else: 1.0

      :upfront ->
        week =
          case dow do
            :fri -> 0.55
            :sat -> 1.3
            _ -> 1.0
          end

        week * if day > dim - 3, do: 1.25, else: 1.0

      k when k in [:recurring, :defaults_raised, :cancel_within, :refunds] ->
        run

      k when k in [:defaults_collected, :prior_recoveries] ->
        0.6 * run + 0.4
    end
  end

  defp dow(meta, day) do
    case Date.day_of_week(Date.new!(meta.year, meta.month, day)) do
      5 -> :fri
      6 -> :sat
      7 -> :sun
      _ -> :weekday
    end
  end

  defp actuals_by_day(month, club_id, dim) do
    base = Map.new(1..dim, &{&1, Map.merge(zero_kpis(), %{txn_known: false})})

    by_day =
      Enum.reduce(Gm.rows_for(month, club_id), base, fn row, acc ->
        Map.update!(acc, row.date.day, fn k ->
          txn = Map.get(row, :transactions)

          %{
            k
            | recurring: k.recurring + row.recurring_collected,
              new_sales: k.new_sales + row.flows.new_sales,
              prior_recoveries:
                k.prior_recoveries + row.flows.prior_default_collections +
                  row.flows.agency_collections,
              upfront: k.upfront + row.flows.upfront,
              defaults_raised: k.defaults_raised + row.defaults_raised,
              defaults_collected: k.defaults_collected + row.defaults_recovered,
              defaults_outstanding: k.defaults_outstanding + row.flows.defaults,
              cancel_within: k.cancel_within + row.flows.cancel_within,
              refunds: k.refunds + row.flows.refunds,
              transactions: k.transactions + (txn || 0),
              txn_known: k.txn_known or txn != nil
          }
        end)
      end)

    # When the feed carries the day's transaction count, recurring dues are
    # the plug so the stack sums exactly to it; otherwise the count is the
    # sum of what was collected.
    # The count is the truth for the day's movement; on a day where the typed
    # rows over-attribute (feed gaps), the stack can exceed the net marker.
    Map.new(by_day, fn {day, k} ->
      k =
        if k.txn_known do
          typed = k.new_sales + k.prior_recoveries + k.upfront + k.defaults_collected
          %{k | recurring: max(k.transactions - typed, 0), net: k.transactions}
        else
          %{k | transactions: net_of(k), net: net_of(k)}
        end

      {day, Map.delete(k, :txn_known)}
    end)
  end

  # Full-month plan for a KPI from the bridge — the comparator when no target exists.
  defp plan_total(month, club_id, kpi) do
    club_id
    |> Gm.club_ids()
    |> Enum.map(fn id ->
      case Bridge.bridge_for(id, month) do
        nil ->
          0

        b ->
          case kpi do
            :recurring ->
              Map.get(b, :recurring_collected) ||
                max(round((b.opening - b.flows.duplicates) * 0.93), 0)

            :new_sales -> b.flows.new_sales
            :prior_recoveries -> b.flows.prior_default_collections + b.flows.agency_collections
            :upfront -> b.flows.upfront
            :defaults_raised -> b.defaults_raised
            :defaults_collected -> b.defaults_recovered
            :cancel_within -> b.flows.cancel_within
            :refunds -> b.flows.refunds
          end
      end
    end)
    |> Enum.sum()
  end

  defp billing_due_on(month, club_id, day) do
    Bridge.billing_runs(month)
    |> Enum.filter(fn r -> r.day == day and (club_id == Gm.all_clubs() or r.club_id == club_id) end)
    |> Enum.map(& &1.members_due)
    |> Enum.sum()
  end

  # Month-end target for one KPI: outturn month-end for run-driven, approved T2
  # where it exists, otherwise the bridge plan.
  defp kpi_target(month, club_id, kpi, target_values, source, month_end) do
    target_key = %{new_sales: :new_sales, upfront: :upfront, prior_recoveries: :prior_recoveries}[kpi]

    cond do
      Map.has_key?(month_end, kpi) -> Map.fetch!(month_end, kpi)
      target_key && source != :fallback && Map.has_key?(target_values, target_key) ->
        Map.fetch!(target_values, target_key)
      true -> plan_total(month, club_id, kpi)
    end
  end

  @dow_names %{1 => "Mon", 2 => "Tue", 3 => "Wed", 4 => "Thu", 5 => "Fri", 6 => "Sat", 7 => "Sun"}

  @doc """
  Build the daily model. `target_values` is the resolved T2 target set for the
  month; `source` is :approved | :draft | :fallback; `month_end` carries the
  outturn's month-end KPI totals and `outturn_close` its close.
  """
  def build(month, club_id, target_values \\ %{}, source \\ :fallback, month_end \\ %{}, outturn_close \\ nil) do
    meta = Bridge.month_meta(month) || hd(Bridge.months())
    dim = Bridge.days_in_month(meta)
    current? = month == Bridge.current_month_key()
    days_elapsed = if current?, do: min(Bridge.today_day(), dim), else: dim
    days_left = dim - days_elapsed

    actual = actuals_by_day(month, club_id, dim)
    prev_month = Gm.previous_month_of(month)
    prev_meta = Bridge.month_meta(prev_month) || meta
    prev_actual = actuals_by_day(prev_month, club_id, Bridge.days_in_month(prev_meta))

    # The billing schedule: members due to run on each day of the month (the
    # feed's runs, filled from weekday averages for days not yet fed).
    due_by_day = for day <- 1..dim, do: billing_due_on(month, club_id, day)
    due_known? = Enum.sum(due_by_day) > 0

    weights =
      Map.new(@kpi_keys, fn key ->
        shaped =
          cond do
            key in @run_scheduled and due_known? ->
              Enum.map(due_by_day, &(&1 * 1.0))

            source == :fallback ->
              for i <- 1..dim do
                prev = Map.get(prev_actual, i, zero_kpis())
                Map.fetch!(prev, key) + 0.05
              end

            true ->
              for day <- 1..dim, do: weight_for(key, day, dow(meta, day), dim)
          end

        {key, shaped}
      end)

    targets =
      Map.new(@kpi_keys, fn key ->
        {key, kpi_target(month, club_id, key, target_values, source, month_end)}
      end)

    # Recurring dues close the month to the outturn: whatever the typed
    # transactions do not account for.
    targets =
      if outturn_close != nil do
        typed = targets.new_sales + targets.upfront + targets.prior_recoveries + targets.defaults_collected
        %{targets | recurring: max(round(outturn_close) - typed, 0)}
      else
        targets
      end

    mtd_of = fn key ->
      Enum.reduce(1..max(days_elapsed, 0)//1, 0, fn d, acc -> acc + Map.fetch!(actual[d], key) end)
    end

    planned =
      Map.new(@kpi_keys, fn key ->
        {key, GmBmd.Bridge.Shape.distribute(targets[key], weights[key])}
      end)

    remaining_split =
      Map.new(@kpi_keys, fn key ->
        left = max(targets[key] - mtd_of.(key), 0)
        future_w = weights[key] |> Enum.with_index(1) |> Enum.map(fn {w, d} -> if d > days_elapsed, do: w, else: 0 end)
        {key, GmBmd.Bridge.Shape.distribute(left, future_w)}
      end)

    # Count basis: the running position starts at zero and accrues the day's
    # transactions; it equals the MTD transaction count on every past day.
    opening = 0

    {rows, _closing} =
      Enum.map_reduce(1..dim, opening, fn day, closing ->
        i = day - 1
        past? = day <= days_elapsed

        fc =
          Enum.reduce(@kpi_keys, zero_kpis(), fn key, acc ->
            source_list = if past?, do: planned[key], else: remaining_split[key]
            Map.put(acc, key, Enum.at(source_list, i, 0))
          end)

        fc = %{fc | defaults_outstanding: max(fc.defaults_raised - fc.defaults_collected, 0)}
        fc = %{fc | net: net_of(fc)}

        act = if past?, do: actual[day]
        closing = closing + if(act, do: act.net, else: fc.net)
        d = Date.new!(meta.year, meta.month, day)
        dow_idx = Date.day_of_week(d)

        row = %{
          date: d,
          day: day,
          dow: @dow_names[dow_idx],
          weekend: dow_idx in [5, 6],
          today: current? and day == days_elapsed,
          past: past?,
          billing_due: Enum.at(due_by_day, i, 0),
          forecast: fc,
          actual: act,
          closing_position: closing
        }

        {row, closing}
      end)

    past = Enum.filter(rows, & &1.past)
    future = Enum.reject(rows, & &1.past)
    mtd_actual_total = past |> Enum.map(& &1.actual.net) |> Enum.sum()
    mtd_forecast_total = past |> Enum.map(& &1.forecast.net) |> Enum.sum()
    closing_actual = opening + mtd_actual_total

    # Reconcile to the outturn so both pages close on the same number. The
    # residual goes to recurring dues on the last forecast day; if that would
    # go negative, it is taken from the other positives on that day (never
    # below zero) — a count cannot fall, so an outturn below the MTD count is
    # left as an `unreconciled` gap rather than faked.
    {rows, unreconciled} =
      if outturn_close != nil and future != [] do
        future_net = future |> Enum.map(& &1.forecast.net) |> Enum.sum()
        residual = round(outturn_close - (closing_actual + future_net))
        last_future_day = List.last(future).day

        rows =
          Enum.map(rows, fn row ->
            if row.day == last_future_day and residual != 0 do
              %{row | forecast: absorb_residual(row.forecast, residual)}
            else
              row
            end
          end)

        {rows, _} =
          Enum.map_reduce(rows, opening, fn row, running ->
            running = running + if(row.actual, do: row.actual.net, else: row.forecast.net)
            {%{row | closing_position: running}, running}
          end)

        {rows, round(outturn_close) - List.last(rows).closing_position}
      else
        {rows, 0}
      end

    future = Enum.reject(rows, & &1.past)
    month_forecast_close = if rows == [], do: opening, else: List.last(rows).closing_position
    month_target = Map.get(target_values, :total, month_forecast_close)

    columns =
      Enum.map(@daily_kpis, fn kpi ->
        mtd = past |> Enum.map(& &1.actual[kpi.key]) |> Enum.sum()
        rem = future |> Enum.map(& &1.forecast[kpi.key]) |> Enum.sum()

        %{key: kpi.key, mtd_actual: mtd, remaining_forecast: rem, month_total: mtd + rem, target: targets[kpi.key]}
      end) ++
        [
          %{
            key: :net,
            mtd_actual: mtd_actual_total,
            remaining_forecast: future |> Enum.map(& &1.forecast.net) |> Enum.sum(),
            month_total: month_forecast_close - opening,
            target: month_target - opening
          }
        ]

    reforecast =
      if days_left > 0 and days_elapsed > 1 do
        Enum.flat_map(@daily_kpis, fn kpi ->
          mtd = mtd_of.(kpi.key)

          yesterday_mtd =
            Enum.reduce(1..(days_elapsed - 1), 0, fn d, acc -> acc + Map.fetch!(actual[d], kpi.key) end)

          now = round(max(targets[kpi.key] - mtd, 0) / max(days_left, 1))
          was = round(max(targets[kpi.key] - yesterday_mtd, 0) / max(days_left + 1, 1))
          if now != was, do: [%{label: kpi.label, now: now, was: was}], else: []
        end)
      else
        []
      end

    %{
      month: month,
      month_label: meta.label,
      rows: rows,
      opening: opening,
      days_total: dim,
      days_elapsed: days_elapsed,
      days_left: days_left,
      mtd_actual_total: mtd_actual_total,
      mtd_forecast_total: mtd_forecast_total,
      variance: mtd_actual_total - mtd_forecast_total,
      closing_actual: closing_actual,
      month_forecast_close: month_forecast_close,
      unreconciled: unreconciled,
      month_target: month_target,
      need_per_day: round(GmBmd.Rules.need_per_day(closing_actual, month_target, days_left)),
      columns: columns,
      reforecast: reforecast,
      source: source
    }
  end

  # Apply a residual to a forecast day's positives: recurring first, then the
  # typed rows, none below zero.
  defp absorb_residual(fc, residual) do
    {fc, _left} =
      Enum.reduce([:recurring, :new_sales, :upfront, :prior_recoveries, :defaults_collected], {fc, residual}, fn key, {fc, left} ->
        if left == 0 do
          {fc, 0}
        else
          current = Map.fetch!(fc, key)
          new = max(current + left, 0)
          {Map.put(fc, key, new), left - (new - current)}
        end
      end)

    %{fc | net: net_of(fc)}
  end

  @doc "TSV of the day table for the copy button."
  def tsv(model) do
    head =
      ["Date", "Day", "Forecast total", "Actual total", "Variance"] ++
        Enum.map(@daily_kpis, & &1.label) ++ ["Net", "Running total"]

    lines =
      Enum.map(model.rows, fn r ->
        src = r.actual || r.forecast

        ([
           Date.to_iso8601(r.date),
           r.dow,
           r.forecast.net,
           if(r.actual, do: r.actual.net, else: ""),
           if(r.actual, do: r.actual.net - r.forecast.net, else: "")
         ] ++
           Enum.map(@daily_kpis, &src[&1.key]) ++ [src.net, r.closing_position])
        |> Enum.map_join("\t", &to_string/1)
      end)

    Enum.join([Enum.join(head, "\t") | lines], "\n")
  end
end
