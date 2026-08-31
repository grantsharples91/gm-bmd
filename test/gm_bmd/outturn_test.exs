defmodule GmBmd.OutturnTest do
  use ExUnit.Case, async: true

  alias GmBmd.{Bridge, Daily, Gm, Outturn}

  @override %{total_target: 10_000, new_sales_target: 500}

  test "outturn base = opening + signed forecasts" do
    month = Bridge.current_month_key()
    ot = Outturn.build(Gm.all_clubs(), month, @override)

    expected = Enum.reduce(ot.rows, ot.opening, fn r, acc -> acc + r.sign * r.forecast end)
    assert ot.base == expected
    assert ot.net_growth == ot.base - ot.opening
    assert ot.worst <= ot.base and ot.base <= ot.best
  end

  test "fixed rows forecast equals actual" do
    month = Bridge.current_month_key()
    ot = Outturn.build(Gm.all_clubs(), month, @override)

    for row <- ot.rows, row.fixed do
      assert row.remaining == 0
      assert row.forecast == row.mtd
      assert row.driver == :fixed
    end
  end

  test "sales overrides move the base" do
    month = Bridge.current_month_key()
    base = Outturn.build(Gm.all_clubs(), month, @override)
    bumped = Outturn.build(Gm.all_clubs(), month, @override, %{}, %{new_sales: 999_999})
    assert bumped.base > base.base
  end

  test "daily model closes on exactly the outturn base" do
    month = Bridge.current_month_key()

    for club_id <- [Gm.all_clubs() | Enum.map(Bridge.clubs(), & &1.id)] do
      ot = Outturn.build(club_id, month, @override)

      model =
        Daily.build(
          month,
          club_id,
          %{total: @override.total_target, new_sales: @override.new_sales_target},
          :approved,
          Outturn.daily_month_end_totals(ot),
          ot.base
        )

      assert model.month_forecast_close == ot.base,
             "daily close #{model.month_forecast_close} != outturn #{ot.base} for #{club_id}"
    end
  end

  test "daily MTD actuals reconcile with the bridge snapshot" do
    month = Bridge.current_month_key()
    club = Gm.all_clubs()
    ot = Outturn.build(club, month, @override)

    model =
      Daily.build(month, club, %{}, :approved, Outturn.daily_month_end_totals(ot), ot.base)

    # Count basis: the daily running position is the MTD transactions
    # collected (on the feed that is THOR's count — see thor_feed_test).
    agg = Gm.aggregate(Gm.rows_for(month, club, Bridge.today_day()))
    assert model.closing_actual == agg.collected_transactions
  end

  test "defaults forecast reconciliation leaves position unchanged at prefill" do
    month = Bridge.current_month_key()
    ot = Outturn.build(Gm.all_clubs(), month, @override)
    df = Outturn.defaults_forecast(ot)
    assert df.system_forecast == df.mtd_outstanding + df.remaining_not_recovered
  end
end
