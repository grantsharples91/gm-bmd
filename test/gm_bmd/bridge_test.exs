defmodule GmBmd.BridgeTest do
  use ExUnit.Case, async: true

  alias GmBmd.Bridge
  alias GmBmd.Bridge.Seeds
  alias GmBmd.Gm

  test "distribute splits a total into integers that sum exactly" do
    weights = [0.5, 1.0, 2.0, 0.1, 3.3]
    out = Seeds.distribute(1234, weights)
    assert Enum.sum(out) == 1234
    assert Enum.all?(out, &(&1 >= 0))
    assert Seeds.distribute(0, weights) |> Enum.sum() == 0
  end

  test "month bridges chain: each opening equals the prior total" do
    for club <- Bridge.clubs() do
      bridges =
        Bridge.month_bridges()
        |> Enum.filter(&(&1.club_id == club.id))
        |> Enum.sort_by(& &1.month)

      bridges
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] -> assert b.opening == a.total end)

      for b <- bridges do
        expected =
          Enum.reduce(Bridge.bridge_rows(), b.opening, fn row, acc ->
            acc + row.sign * Map.fetch!(b.flows, row.key)
          end)

        assert b.total == expected
        assert b.net_growth == b.total - b.opening
      end
    end
  end

  test "daily accrual reconciles to the month bridge, per club and flow" do
    month = Bridge.current_month_key()

    for club <- Bridge.clubs() do
      bridge = Bridge.bridge_for(club.id, month)
      rows = Bridge.day_rows(month) |> Enum.filter(&(&1.club_id == club.id))

      for key <- Bridge.bridge_row_keys() do
        daily_sum = rows |> Enum.map(& &1.flows[key]) |> Enum.sum()
        assert daily_sum == Map.fetch!(bridge.flows, key), "flow #{key} mismatch for #{club.id}"
      end

      assert Enum.map(rows, & &1.defaults_raised) |> Enum.sum() == bridge.defaults_raised
      assert Enum.map(rows, & &1.defaults_recovered) |> Enum.sum() == bridge.defaults_recovered
    end
  end

  test "fixed rows land in full on day 1" do
    month = Bridge.current_month_key()

    for club <- Bridge.clubs() do
      bridge = Bridge.bridge_for(club.id, month)
      rows = Bridge.day_rows(month) |> Enum.filter(&(&1.club_id == club.id))
      day1 = Enum.find(rows, &(&1.date.day == 1))

      for key <- Bridge.fixed_rows() do
        assert day1.flows[key] == Map.fetch!(bridge.flows, key)
        assert rows |> Enum.reject(&(&1.date.day == 1)) |> Enum.map(& &1.flows[key]) |> Enum.sum() == 0
      end
    end
  end

  test "bridge snapshot full month equals the month bridge totals" do
    month = Bridge.current_month_key()
    snap = Gm.bridge_snapshot(month, Gm.all_clubs())

    expected_total =
      Bridge.month_bridges() |> Enum.filter(&(&1.month == month)) |> Enum.map(& &1.total) |> Enum.sum()

    assert snap.total == expected_total
  end

  test "billing runs sum to the recurring base" do
    month = Bridge.current_month_key()

    for club <- Bridge.clubs() do
      bridge = Bridge.bridge_for(club.id, month)
      base = round((bridge.opening - bridge.flows.duplicates) * 0.93)

      due =
        Bridge.billing_runs(month)
        |> Enum.filter(&(&1.club_id == club.id))
        |> Enum.map(& &1.members_due)
        |> Enum.sum()

      assert due == base
    end
  end
end
