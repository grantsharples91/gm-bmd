defmodule GmBmd.Revenue do
  @moduledoc """
  Revenue and yield — the money view of the transaction bridge. Revenue is
  always derived from transaction counts × unit AED, so it can never disagree
  with the bridge. Yield = revenue ÷ collecting transactions.
  """

  alias GmBmd.Bridge
  alias GmBmd.Gm

  @doc "The revenue streams behind MTD revenue, biggest first."
  def streams(t) do
    unit = Bridge.unit_aed()
    prior = t.flows.prior_default_collections + t.flows.agency_collections

    raw = [
      %{
        key: :recurring,
        label: "Recurring dues",
        note: "Monthly billing runs collected",
        txns: t.recurring_collected,
        unit: unit.recurring,
        revenue: t.recurring_collected * unit.recurring,
        yield: unit.recurring,
        sign: 1
      },
      %{
        key: :new_sale,
        label: "New sales",
        note: "First payment on new recurring memberships",
        txns: t.flows.new_sales,
        unit: unit.new_sale,
        revenue: t.flows.new_sales * unit.new_sale,
        yield: unit.new_sale,
        sign: 1
      },
      %{
        key: :upfront,
        label: "Upfront / PIF",
        note: "Remaining contract instalments collected early — same value per payment, more transactions",
        txns: t.flows.upfront,
        unit: unit.upfront,
        revenue: t.flows.upfront * unit.upfront,
        yield: unit.upfront,
        sign: 1
      },
      %{
        key: :recovery,
        label: "Default recoveries",
        note: "This month's defaults recovered inside the month",
        txns: t.defaults_recovered,
        unit: unit.recovery,
        revenue: t.defaults_recovered * unit.recovery,
        yield: unit.recovery,
        sign: 1
      },
      %{
        key: :prior_recovery,
        label: "Prior-month recoveries",
        note: "Collections on prior-month defaults, including third-party debt agency",
        txns: prior,
        unit: unit.recovery,
        revenue: prior * unit.recovery,
        yield: unit.recovery,
        sign: 1
      },
      %{
        key: :refund,
        label: "Refunds",
        note: "Netted off revenue and out of the base",
        txns: t.flows.refunds,
        unit: unit.refund,
        revenue: -t.flows.refunds * unit.refund,
        yield: -unit.refund,
        sign: -1
      }
    ]

    gross = raw |> Enum.filter(&(&1.sign == 1)) |> Enum.map(& &1.revenue) |> Enum.sum() |> max(1)

    raw
    |> Enum.map(&Map.put(&1, :share, &1.revenue / gross))
    |> Enum.sort_by(&(-abs(&1.revenue)))
  end

  def view(month, club_id, through_day \\ nil) do
    totals = Gm.aggregate(Gm.rows_for(month, club_id, through_day))
    streams = streams(totals)
    gross = streams |> Enum.filter(&(&1.sign == 1)) |> Enum.map(& &1.revenue) |> Enum.sum()
    refunds = streams |> Enum.filter(&(&1.sign == -1)) |> Enum.map(& &1.revenue) |> Enum.sum()
    net = gross + refunds

    %{
      totals: totals,
      streams: streams,
      gross: gross,
      refunds: refunds,
      net: net,
      yield:
        if(totals.collected_transactions > 0,
          do: net / totals.collected_transactions,
          else: Gm.avg_txn_aed()
        ),
      revenue_target: Gm.finance_targets_for(club_id).revenue_target
    }
  end

  @doc "Per-club revenue and yield for the drill-down table."
  def by_club(month, through_day \\ nil) do
    Bridge.clubs()
    |> Enum.map(fn c ->
      v = view(month, c.id, through_day)
      upfront = Enum.find(v.streams, &(&1.key == :upfront))

      %{
        club_id: c.id,
        name: c.name,
        revenue: v.net,
        yield: v.yield,
        txns: v.totals.collected_transactions,
        upfront_mix: if(v.gross > 0, do: (upfront && upfront.revenue || 0) / v.gross, else: 0.0)
      }
    end)
    |> Enum.sort_by(&(-&1.revenue))
  end
end
