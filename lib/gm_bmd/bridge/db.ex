defmodule GmBmd.Bridge.DB do
  @moduledoc """
  The production data feed — `GmBmd.Bridge.Source` over the `bridge_*` tables.

  The tables are filled by THOR (see `GmBmd.Bridge.Ingest`): clubs, one bridge
  row per club-month, day rows for the months the feed covers by day, and the
  billing schedule. Everything is read once into `:persistent_term` and
  re-read after each ingest (`reload/0`).

  What the feed does not carry, this module synthesises so every screen keeps
  working:

    * day rows for months that only exist as monthly totals — accrued with
      `GmBmd.Bridge.Synth`, reconciling exactly to the bridge;
    * three forward months (kind `:forecast`) after the last actual month, so
      GM TARGETS can be set ahead — flows copied from the last full month;
    * billing runs for the days after the feed's as-of date, from the
      month-to-date weekday averages.

  Openings chain: each month opens on the prior month's closing — the site
  manager's override (`GmBmd.Closings`) when one is set, otherwise the
  computed total. Only the first month in the feed keeps its own opening.

  If the tables are empty (first boot before the loader runs) the seeded
  placeholder feed answers instead, so the dashboard never renders blank.
  """

  @behaviour GmBmd.Bridge.Source

  import Ecto.Query

  alias GmBmd.Bridge
  alias GmBmd.Bridge.{Seeds, Shape, Synth}
  alias GmBmd.Repo

  @cache_key {__MODULE__, :data}
  @forecast_months 3
  @month_names ~w(January February March April May June July August September October November December)

  # ------------------------------------------------------------------ Source

  @impl true
  def clubs, do: with_data(& &1.clubs, &Seeds.clubs/0)

  @impl true
  def months, do: with_data(& &1.months, &Seeds.months/0)

  @impl true
  def month_bridges, do: with_data(& &1.month_bridges, &Seeds.month_bridges/0)

  @impl true
  def day_rows(month),
    do: with_data(&Map.get(&1.day_rows, month, []), fn -> Seeds.day_rows(month) end)

  @impl true
  def billing_runs(month),
    do: with_data(&Map.get(&1.billing_runs, month, []), fn -> Seeds.billing_runs(month) end)

  @impl true
  def finance_targets, do: with_data(& &1.finance_targets, &Seeds.finance_targets/0)

  @impl true
  def as_of, do: with_data(& &1.as_of, fn -> nil end)

  @doc "True when the tables hold a feed (as opposed to the seeded fallback)."
  def loaded?, do: match?(%{}, data())

  @doc "Feed provenance for the UI: %{as_of, source, generated_at} or nil."
  def provenance do
    case data() do
      :empty -> nil
      d -> %{as_of: d.as_of, source: d.meta["source"], generated_at: d.meta["generated_at"]}
    end
  end

  @doc "Drop the cache; the next read rebuilds it from the tables."
  def reload do
    :persistent_term.erase(@cache_key)
    :ok
  end

  # ------------------------------------------------------------------- cache

  defp with_data(fun, fallback) do
    case data() do
      :empty -> fallback.()
      d -> fun.(d)
    end
  end

  defp data do
    case :persistent_term.get(@cache_key, :miss) do
      :miss ->
        value = build()
        :persistent_term.put(@cache_key, value)
        value

      value ->
        value
    end
  end

  # ------------------------------------------------------------------- build

  defp build do
    raw_months = read_months()

    if raw_months == [] do
      :empty
    else
      meta = read_meta()
      as_of = parse_date(meta["as_of"])
      clubs = read_clubs()
      club_ids = Enum.map(clubs, & &1.id)

      actual_keys = raw_months |> Enum.map(& &1.month) |> Enum.uniq() |> Enum.sort()
      last_actual = List.last(actual_keys)
      forecast_keys = next_month_keys(last_actual, @forecast_months)

      months =
        Enum.map(actual_keys, &month_meta(&1, :actual)) ++
          Enum.map(forecast_keys, &month_meta(&1, :forecast))

      # A "full" month is one the feed has closed — strictly before the as-of month.
      current_key =
        case as_of do
          %Date{} = d -> Bridge.month_key(d.year, d.month)
          nil -> Bridge.month_key(Bridge.today_dubai().year, Bridge.today_dubai().month)
        end

      full_keys = Enum.filter(actual_keys, &(&1 < current_key))
      template_key = List.last(full_keys) || last_actual

      overrides = GmBmd.Closings.all()

      # Chain the months per club: every opening is the prior month's closing
      # (the manager's override when set, else the computed total). Only the
      # first month keeps the opening the feed supplied.
      actual_bridges =
        Enum.flat_map(club_ids, fn club_id ->
          {rows, _} =
            raw_months
            |> Enum.filter(&(&1.club_id == club_id))
            |> Enum.sort_by(& &1.month)
            |> Enum.map_reduce(nil, fn m, carried ->
              opening = carried || m.opening
              total = flow_total(opening, m.flows)
              override = Map.get(overrides, {club_id, m.month})

              row =
                Map.merge(m, %{
                  opening: opening,
                  total: total,
                  net_growth: total - opening,
                  closing: (override && override.value) || total,
                  closing_override: override
                })

              {row, row.closing}
            end)

          rows
        end)

      forecast_bridges =
        Enum.flat_map(club_ids, fn club_id ->
          by_month = actual_bridges |> Enum.filter(&(&1.club_id == club_id)) |> Map.new(&{&1.month, &1})
          template = Map.get(by_month, template_key) || Map.get(by_month, last_actual)
          last = Map.get(by_month, last_actual)

          if template && last do
            {rows, _} =
              Enum.map_reduce(forecast_keys, last.closing, fn key, opening ->
                total = flow_total(opening, template.flows)

                row = %{
                  club_id: club_id,
                  month: key,
                  kind: :forecast,
                  opening: opening,
                  flows: template.flows,
                  defaults_raised: template.defaults_raised,
                  defaults_recovered: template.defaults_recovered,
                  total: total,
                  net_growth: total - opening,
                  revenue_aed: template.revenue_aed,
                  recurring_collected: template.recurring_collected,
                  closing: total,
                  closing_override: nil
                }

                {row, total}
              end)

            rows
          else
            []
          end
        end)

      month_bridges = actual_bridges ++ forecast_bridges
      day_rows = build_day_rows(months, month_bridges, read_days())
      billing_runs = build_billing_runs(months, month_bridges, read_runs(), as_of)

      %{
        clubs: clubs,
        months: months,
        month_bridges: month_bridges,
        day_rows: day_rows,
        billing_runs: billing_runs,
        finance_targets: finance_targets(club_ids, month_bridges, template_key),
        as_of: as_of,
        meta: meta
      }
    end
  end

  # Day rows: the feed's own rows where a club-month has any, otherwise an
  # accrual synthesised from the bridge.
  defp build_day_rows(months, month_bridges, fed_rows) do
    fed_by_month = Enum.group_by(fed_rows, &Bridge.month_key(&1.date.year, &1.date.month))

    Map.new(months, fn meta ->
      fed = Map.get(fed_by_month, meta.key, [])
      fed_clubs = fed |> Enum.map(& &1.club_id) |> MapSet.new()

      synthesised =
        month_bridges
        |> Enum.filter(&(&1.month == meta.key and not MapSet.member?(fed_clubs, &1.club_id)))
        |> Enum.flat_map(&Synth.day_rows(&1.club_id, &1, meta.year, meta.month))

      rows = Enum.sort_by(fed ++ synthesised, &{&1.club_id, Date.to_iso8601(&1.date)})
      {meta.key, rows}
    end)
  end

  # Billing runs: the feed's rows, with the rest of the month filled from the
  # weekday averages seen so far (or a synthesised schedule when there are none).
  defp build_billing_runs(months, month_bridges, fed_runs, _as_of) do
    fed_by_month = Enum.group_by(fed_runs, &Bridge.month_key(&1.date.year, &1.date.month))

    Map.new(months, fn meta ->
      dim = Bridge.days_in_month(meta)
      fed = Map.get(fed_by_month, meta.key, []) |> Enum.group_by(& &1.club_id)

      runs =
        month_bridges
        |> Enum.filter(&(&1.month == meta.key))
        |> Enum.flat_map(fn bridge ->
          case Map.get(fed, bridge.club_id, []) do
            [] ->
              Synth.billing_runs(bridge.club_id, bridge, meta.year, meta.month)

            club_runs ->
              have = Map.new(club_runs, &{&1.date.day, &1})
              fill = fill_from_averages(club_runs)

              for day <- 1..dim do
                date = Date.new!(meta.year, meta.month, day)

                case Map.get(have, day) do
                  nil ->
                    fill.(date)
                    |> Map.merge(%{club_id: bridge.club_id, month: meta.key, day: day, date: date})

                  run ->
                    Map.merge(run, %{month: meta.key, day: day})
                end
              end
          end
        end)

      {meta.key, runs}
    end)
  end

  defp fill_from_averages(club_runs) do
    by_dow = Enum.group_by(club_runs, &Shape.dow(&1.date))
    overall_due = mean(Enum.map(club_runs, & &1.members_due))
    overall_pct = mean(Enum.map(club_runs, & &1.last_collected_pct))

    fn date ->
      case Map.get(by_dow, Shape.dow(date)) do
        nil ->
          %{members_due: round(overall_due), last_collected_pct: overall_pct}

        same ->
          %{
            members_due: round(mean(Enum.map(same, & &1.members_due))),
            last_collected_pct: mean(Enum.map(same, & &1.last_collected_pct))
          }
      end
    end
  end

  # Finance targets: hold the last full month flat — the placeholder until
  # T2 targets are set per club on the GM TARGETS screen.
  defp finance_targets(club_ids, month_bridges, template_key) do
    Enum.map(club_ids, fn club_id ->
      case Enum.find(month_bridges, &(&1.club_id == club_id and &1.month == template_key)) do
        nil ->
          %{club_id: club_id, new_sales_target: 0, upfront_target: 0, total_target: 0, revenue_target: 0}

        b ->
          %{
            club_id: club_id,
            new_sales_target: b.flows.new_sales,
            upfront_target: b.flows.upfront,
            total_target: b.total,
            revenue_target: round(b.revenue_aed / 10_000) * 10_000
          }
      end
    end)
  end

  # ------------------------------------------------------------------- reads

  defp read_clubs do
    from(c in "bridge_clubs",
      order_by: [asc: c.sort, asc: c.name],
      select: %{id: c.id, name: c.name, city: c.city}
    )
    |> Repo.all()
  end

  defp read_months do
    from(m in "bridge_months",
      order_by: [asc: m.club_id, asc: m.month],
      select: %{
        club_id: m.club_id,
        month: m.month,
        kind: m.kind,
        opening: m.opening,
        flows: m.flows,
        defaults_raised: m.defaults_raised,
        defaults_recovered: m.defaults_recovered,
        total: m.total,
        net_growth: m.net_growth,
        revenue_aed: m.revenue_aed,
        recurring_collected: m.recurring_collected
      }
    )
    |> Repo.all()
    |> Enum.map(fn m ->
      %{m | kind: String.to_atom(m.kind), flows: atomise_flows(m.flows)}
    end)
  end

  defp read_days do
    from(d in "bridge_days",
      select: %{
        club_id: d.club_id,
        date: d.date,
        flows: d.flows,
        defaults_raised: d.defaults_raised,
        defaults_recovered: d.defaults_recovered,
        recurring_collected: d.recurring_collected,
        revenue_aed: d.revenue_aed
      }
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | flows: atomise_flows(&1.flows)})
  end

  defp read_runs do
    from(r in "billing_runs",
      select: %{
        club_id: r.club_id,
        date: r.date,
        members_due: r.members_due,
        last_collected_pct: r.last_collected_pct
      }
    )
    |> Repo.all()
  end

  defp read_meta do
    from(m in "bridge_meta", select: {m.key, m.value}) |> Repo.all() |> Map.new()
  end

  # ----------------------------------------------------------------- helpers

  defp atomise_flows(flows) do
    Map.new(Bridge.bridge_row_keys(), fn key ->
      {key, round(Map.get(flows, to_string(key)) || Map.get(flows, key) || 0)}
    end)
  end

  defp flow_total(opening, flows) do
    Enum.reduce(Bridge.bridge_rows(), opening, fn row, acc ->
      acc + row.sign * Map.fetch!(flows, row.key)
    end)
  end

  defp month_meta(key, kind) do
    [y, m] = key |> String.split("-") |> Enum.map(&String.to_integer/1)

    %{
      key: key,
      label: "#{Enum.at(@month_names, m - 1)} #{y}",
      year: y,
      month: m,
      kind: kind
    }
  end

  defp next_month_keys(key, count) do
    [y, m] = key |> String.split("-") |> Enum.map(&String.to_integer/1)

    Enum.map(1..count, fn i ->
      date = Date.new!(y, m, 1) |> Date.shift(month: i)
      Bridge.month_key(date.year, date.month)
    end)
  end

  defp parse_date(nil), do: nil

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp mean([]), do: 0.0
  defp mean(list), do: Enum.sum(list) / length(list)
end
