defmodule GmBmd.Bridge.Seeds do
  @moduledoc """
  Deterministic placeholder data — the membership-analysis bridge per club per
  month with a daily accrual, ported from the finance-sheet shape. Magnitudes
  come from the Motor City Aug-2026 actuals; the other clubs are scaled to
  60–110%. Everything is generated once and cached in `:persistent_term`.

  This module is the stand-in for the production database feed: it implements
  `GmBmd.Bridge.Source`, and nothing outside it knows the numbers are seeded.
  """

  @behaviour GmBmd.Bridge.Source

  alias GmBmd.Bridge

  @clubs [
    %{id: "club-motor-city", name: "Motor City", city: "Dubai"},
    %{id: "club-al-ain", name: "Al Ain", city: "Al Ain"},
    %{id: "club-silicon-oasis", name: "Silicon Oasis", city: "Dubai"},
    %{id: "club-al-quoz", name: "Al Quoz", city: "Dubai"},
    %{id: "club-mirdif", name: "Mirdif", city: "Dubai"}
  ]

  @club_scale %{
    "club-motor-city" => 1.0,
    "club-al-ain" => 0.72,
    "club-silicon-oasis" => 0.94,
    "club-al-quoz" => 0.63,
    "club-mirdif" => 1.08
  }

  # Motor City, Jun–Dec 2026. Jun–Aug actual, Sep–Dec forecast. Flows are
  # always positive magnitudes; the sign lives on the bridge-row meta.
  # :default_recovery is the share of gross defaults recovered inside the month.
  @base_months [
    %{
      year: 2026,
      month: 6,
      kind: :actual,
      opening: 7610,
      default_recovery: 0.66,
      flows: %{
        duplicates: 1120,
        new_sales: 505,
        prior_default_collections: 460,
        upfront: 969,
        agency_collections: 0,
        cancel_within: 30,
        cancel_prior: 610,
        defaults: 240,
        refunds: 22
      }
    },
    %{
      year: 2026,
      month: 7,
      kind: :actual,
      opening: nil,
      default_recovery: 0.67,
      flows: %{
        duplicates: 1050,
        new_sales: 530,
        prior_default_collections: 470,
        upfront: 979,
        agency_collections: 0,
        cancel_within: 65,
        cancel_prior: 658,
        defaults: 250,
        refunds: 18
      }
    },
    %{
      year: 2026,
      month: 8,
      kind: :actual,
      opening: nil,
      default_recovery: 0.685,
      flows: %{
        duplicates: 1258,
        new_sales: 550,
        prior_default_collections: 475,
        upfront: 850,
        agency_collections: 0,
        cancel_within: 20,
        cancel_prior: 525,
        defaults: 200,
        refunds: 15
      }
    },
    %{
      year: 2026,
      month: 9,
      kind: :forecast,
      opening: nil,
      default_recovery: 0.69,
      flows: %{
        duplicates: 1150,
        new_sales: 575,
        prior_default_collections: 475,
        upfront: 825,
        agency_collections: 0,
        cancel_within: 25,
        cancel_prior: 525,
        defaults: 200,
        refunds: 12
      }
    },
    %{
      year: 2026,
      month: 10,
      kind: :forecast,
      opening: nil,
      default_recovery: 0.69,
      flows: %{
        duplicates: 1180,
        new_sales: 590,
        prior_default_collections: 470,
        upfront: 840,
        agency_collections: 0,
        cancel_within: 25,
        cancel_prior: 515,
        defaults: 205,
        refunds: 14
      }
    },
    %{
      year: 2026,
      month: 11,
      kind: :forecast,
      opening: nil,
      default_recovery: 0.7,
      flows: %{
        duplicates: 1200,
        new_sales: 610,
        prior_default_collections: 465,
        upfront: 870,
        agency_collections: 0,
        cancel_within: 22,
        cancel_prior: 505,
        defaults: 210,
        refunds: 13
      }
    },
    %{
      year: 2026,
      month: 12,
      kind: :forecast,
      opening: nil,
      default_recovery: 0.68,
      flows: %{
        duplicates: 1240,
        new_sales: 540,
        prior_default_collections: 460,
        upfront: 780,
        agency_collections: 0,
        cancel_within: 28,
        cancel_prior: 540,
        defaults: 215,
        refunds: 16
      }
    }
  ]

  @month_names ~w(January February March April May June July August September October November December)

  @impl true
  def clubs, do: @clubs

  @impl true
  def months do
    Enum.map(@base_months, fn m ->
      %{
        key: Bridge.month_key(m.year, m.month),
        label: "#{Enum.at(@month_names, m.month - 1)} #{m.year}",
        year: m.year,
        month: m.month,
        kind: m.kind
      }
    end)
  end

  @impl true
  def month_bridges do
    cached({__MODULE__, :month_bridges}, fn ->
      Enum.flat_map(@clubs, fn club ->
        scale = Map.fetch!(@club_scale, club.id)

        {rows, _opening} =
          Enum.map_reduce(@base_months, nil, fn base, prev_total ->
            flows =
              Map.new(base.flows, fn {k, v} -> {k, round(v * scale)} end)

            opening = prev_total || round((base.opening || 0) * scale)

            # The plan figure is GROSS defaults raised; the bridge deducts only
            # the outstanding (unrecovered) balance.
            raised = flows.defaults
            recovered = round(raised * base.default_recovery)
            flows = %{flows | defaults: raised - recovered}

            total = flow_total(opening, flows)

            row = %{
              club_id: club.id,
              month: Bridge.month_key(base.year, base.month),
              kind: base.kind,
              opening: opening,
              flows: flows,
              defaults_raised: raised,
              defaults_recovered: recovered,
              total: total,
              net_growth: total - opening
            }

            {row, total}
          end)

        rows
      end)
    end)
  end

  @impl true
  def day_rows(month) do
    cached({__MODULE__, :day_rows, month}, fn -> accrue(month) end)
  end

  @impl true
  def billing_runs(month) do
    cached({__MODULE__, :billing_runs, month}, fn ->
      case Enum.find(months(), &(&1.key == month)) do
        nil ->
          []

        meta ->
          dim = Bridge.days_in_month(meta)

          Enum.flat_map(@clubs, fn club ->
            case Enum.find(month_bridges(), &(&1.club_id == club.id and &1.month == month)) do
              nil ->
                []

              bridge ->
                base = round((bridge.opening - bridge.flows.duplicates) * 0.93)
                noise = noise_stream("runs-#{club.id}-#{month}", dim)

                weights =
                  for day <- 1..dim do
                    run_shape(day, dow(meta, day), dim) * (0.88 + Enum.at(noise, day - 1) * 0.24)
                  end

                due = distribute(base, weights)
                pct_noise = noise_stream("runpct-#{club.id}-#{month}", dim)

                for day <- 1..dim do
                  %{
                    club_id: club.id,
                    month: month,
                    day: day,
                    date: Date.new!(meta.year, meta.month, day),
                    members_due: Enum.at(due, day - 1),
                    last_collected_pct: 0.9 + Enum.at(pct_noise, day - 1) * 0.06
                  }
                end
            end
          end)
      end
    end)
  end

  @impl true
  def finance_targets do
    current = Bridge.current_month_key()

    Enum.map(@clubs, fn club ->
      scale = Map.fetch!(@club_scale, club.id)
      bridge = Enum.find(month_bridges(), &(&1.club_id == club.id and &1.month == current))
      unit = Bridge.unit_aed()

      revenue =
        round((bridge.opening - bridge.flows.duplicates) * 0.93) * unit.recurring +
          bridge.flows.new_sales * unit.new_sale + bridge.flows.upfront * unit.upfront

      %{
        club_id: club.id,
        new_sales_target: round(575 * scale),
        upfront_target: round(880 * scale),
        total_target: bridge.total,
        revenue_target: round(revenue / 10_000) * 10_000
      }
    end)
  end

  # ------------------------------------------------------------- daily accrual

  defp accrue(month) do
    case Enum.find(months(), &(&1.key == month)) do
      nil ->
        []

      meta ->
        dim = Bridge.days_in_month(meta)

        Enum.flat_map(@clubs, fn club ->
          case Enum.find(month_bridges(), &(&1.club_id == club.id and &1.month == month)) do
            nil -> []
            bridge -> accrue_club(club, bridge, meta, dim)
          end
        end)
    end
  end

  defp accrue_club(club, bridge, meta, dim) do
    seed = "#{club.id}-#{bridge.month}"

    per_key =
      Map.new(Bridge.bridge_row_keys(), fn key ->
        values =
          if Bridge.fixed_row?(key) do
            # Fixed rows land in full on day 1 — known before the month starts.
            [Map.fetch!(bridge.flows, key) | List.duplicate(0, dim - 1)]
          else
            distribute(Map.fetch!(bridge.flows, key), weights_for(key, meta, dim, seed))
          end

        {key, values}
      end)

    recurring_total = round((bridge.opening - bridge.flows.duplicates) * 0.93)
    recurring = distribute(recurring_total, weights_for(:recurring, meta, dim, seed))
    raised = distribute(bridge.defaults_raised, weights_for(:defaults, meta, dim, seed))

    recovered =
      distribute(bridge.defaults_recovered, weights_for(:defaults_recovered, meta, dim, seed))

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
        club_id: club.id,
        date: Date.new!(meta.year, meta.month, day),
        flows: flows,
        defaults_raised: Enum.at(raised, i),
        defaults_recovered: day_recovered,
        recurring_collected: recurring_collected,
        revenue_aed: revenue
      }
    end
  end

  # Weight profiles per bridge row: how the row lands across the days.
  defp weights_for(key, meta, dim, seed) do
    noise = noise_stream("#{key}-#{seed}", dim)

    for day <- 1..dim do
      d = dow(meta, day)
      n = 0.65 + Enum.at(noise, day - 1) * 0.75
      run = run_shape(day, d, dim) * n

      case key do
        # Sales-type rows land unevenly, heavier at weekends and month-end.
        k when k in [:new_sales, :upfront] ->
          week =
            case d do
              :fri -> 0.55
              :sat -> 1.35
              _ -> 1.0
            end

          tail = if day > dim - 4, do: 1.3, else: 1.0
          n * week * tail

        # Run-driven rows follow the size of that day's billing run.
        k when k in [:recurring, :defaults, :refunds, :cancel_within] ->
          run

        # Recoveries trail the day's run.
        k when k in [:prior_default_collections, :defaults_recovered] ->
          0.6 * run + 0.4 * n

        _ ->
          n
      end
    end
  end

  @doc """
  Relative size of one day's billing run. UAE shape: Fri quiet, Sat heavy, and
  the first days of the month carry the recurring anniversaries.
  """
  def run_shape(day, dow, dim) do
    week =
      case dow do
        :fri -> 0.62
        :sat -> 1.28
        :sun -> 1.06
        _ -> 1.0
      end

    start =
      cond do
        day <= 5 -> 1.45
        day <= 10 -> 1.18
        day > dim - 3 -> 1.08
        true -> 1.0
      end

    week * start
  end

  @doc "Split a total across weights as integers that sum exactly to the total."
  def distribute(total, weights) do
    sum = Enum.sum(weights)

    if sum <= 0 do
      List.duplicate(0, length(weights) - 1) ++ [round(total)]
    else
      raw = Enum.map(weights, fn w -> total * w / sum end)
      floors = Enum.map(raw, &floor/1)
      left = round(total) - Enum.sum(floors)

      order =
        raw
        |> Enum.with_index()
        |> Enum.sort_by(fn {v, _i} -> -(v - floor(v)) end)
        |> Enum.map(fn {_v, i} -> i end)

      bump = order |> Stream.cycle() |> Enum.take(max(left, 0)) |> Enum.frequencies()

      floors
      |> Enum.with_index()
      |> Enum.map(fn {v, i} -> v + Map.get(bump, i, 0) end)
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

  # Deterministic noise in [0, 1) — same seed string, same stream, every boot.
  defp noise_stream(seed, count) do
    state =
      :rand.seed_s(
        :exsss,
        {:erlang.phash2(seed, 1_000_000), :erlang.phash2({seed, :a}, 1_000_000),
         :erlang.phash2({seed, :b}, 1_000_000)}
      )

    {values, _} =
      Enum.map_reduce(1..count, state, fn _, s ->
        :rand.uniform_s(s)
      end)

    values
  end

  defp flow_total(opening, flows) do
    Enum.reduce(Bridge.bridge_rows(), opening, fn row, acc ->
      acc + row.sign * Map.fetch!(flows, row.key)
    end)
  end

  defp cached(key, fun) do
    case :persistent_term.get(key, :miss) do
      :miss ->
        value = fun.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end
end
