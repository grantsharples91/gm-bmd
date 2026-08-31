defmodule GmBmd.BridgeDBTest do
  # The DB source caches in :persistent_term, so these tests must not
  # interleave with anything else reading the feed.
  use GmBmd.DataCase, async: false

  alias GmBmd.Bridge
  alias GmBmd.Bridge.{DB, Ingest}

  @snapshot Path.expand("../../priv/bridge/thor_snapshot.json", __DIR__)

  setup do
    DB.reload()
    on_exit(fn -> DB.reload() end)
    :ok
  end

  test "empty tables fall back to the seeded feed" do
    refute DB.loaded?()
    assert DB.as_of() == nil
    assert DB.clubs() == GmBmd.Bridge.Seeds.clubs()
  end

  test "the THOR snapshot loads and answers the Source contract" do
    {:ok, counts} = Ingest.load_file!(@snapshot)
    assert counts.clubs == 36
    assert counts.month_bridges == 36 * 6

    assert DB.loaded?()
    assert DB.as_of() == ~D[2026-08-30]
    assert length(DB.clubs()) == 36
    assert Enum.any?(DB.clubs(), &(&1.name == "Motor City"))

    months = DB.months()
    actual = Enum.filter(months, &(&1.kind == :actual))
    forecast = Enum.filter(months, &(&1.kind == :forecast))
    assert Enum.map(actual, & &1.key) == ~w(2026-03 2026-04 2026-05 2026-06 2026-07 2026-08)
    assert Enum.map(forecast, & &1.key) == ~w(2026-09 2026-10 2026-11)
    assert hd(forecast).label == "September 2026"

    # every club has a bridge in every month, and the bridge identity holds
    for club <- DB.clubs(), meta <- months do
      b = Enum.find(DB.month_bridges(), &(&1.club_id == club.id and &1.month == meta.key))
      assert b, "missing bridge #{club.id} #{meta.key}"

      expected =
        Enum.reduce(Bridge.bridge_rows(), b.opening, fn row, acc ->
          acc + row.sign * Map.fetch!(b.flows, row.key)
        end)

      # the rows explain what they can; the reconciling line closes to THOR's count
      assert b.total == expected + b.reconcile
      assert b.net_growth == b.total - b.opening
      if b.kind == :forecast, do: assert(b.reconcile == 0)
    end

    # the closing total is THOR's transaction count
    mc_aug = Enum.find(DB.month_bridges(), &(&1.club_id == "club-motor-city" and &1.month == "2026-08"))
    assert mc_aug.total == 7365
    assert mc_aug.transactions == 7365
    assert DB.day_rows("2026-08") |> Enum.filter(&(&1.club_id == "club-motor-city")) |> Enum.map(& &1.transactions) |> Enum.sum() == 7365

    # every opening is the prior month's closing — actual and forecast alike
    for club <- DB.clubs() do
      bridges = DB.month_bridges() |> Enum.filter(&(&1.club_id == club.id)) |> Enum.sort_by(& &1.month)

      bridges
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] -> assert b.opening == a.closing and a.closing == a.total end)
    end
  end

  test "a manager closing override becomes the next month's opening" do
    {:ok, _} = Ingest.load_file!(@snapshot)
    jul = Enum.find(DB.month_bridges(), &(&1.club_id == "club-al-ain" and &1.month == "2026-07"))
    aug_before = Enum.find(DB.month_bridges(), &(&1.club_id == "club-al-ain" and &1.month == "2026-08"))
    assert aug_before.opening == jul.total

    GmBmd.Closings.set("club-al-ain", "2026-07", 6000, "grant", "counted at the desk")

    jul = Enum.find(DB.month_bridges(), &(&1.club_id == "club-al-ain" and &1.month == "2026-07"))
    aug = Enum.find(DB.month_bridges(), &(&1.club_id == "club-al-ain" and &1.month == "2026-08"))
    sep = Enum.find(DB.month_bridges(), &(&1.club_id == "club-al-ain" and &1.month == "2026-09"))

    # the overridden month keeps its computed total but carries the manager's figure
    assert jul.closing == 6000
    assert jul.total == aug_before.opening
    assert jul.closing_override.set_by == "grant"
    assert aug.opening == 6000
    # the count does not move — the reconciling line absorbs the new opening
    assert aug.total == aug_before.total
    assert aug.reconcile == aug_before.reconcile - (6000 - aug_before.opening)
    assert sep.opening == aug.closing

    # other clubs untouched
    other = Enum.find(DB.month_bridges(), &(&1.club_id == "club-motor-city" and &1.month == "2026-08"))
    assert other.closing_override == nil

    GmBmd.Closings.clear("club-al-ain", "2026-07")
    aug = Enum.find(DB.month_bridges(), &(&1.club_id == "club-al-ain" and &1.month == "2026-08"))
    assert aug.opening == aug_before.opening
  end

  test "day rows: fed months come from the feed, others reconcile to the bridge" do
    {:ok, _} = Ingest.load_file!(@snapshot)

    # August is fed by day — 31 rows per club, flows matching the feed's month bridge
    aug = DB.day_rows("2026-08")
    assert length(aug) == 36 * 31

    for club <- DB.clubs() do
      rows = Enum.filter(aug, &(&1.club_id == club.id))
      bridge = Enum.find(DB.month_bridges(), &(&1.club_id == club.id and &1.month == "2026-08"))

      for key <- Bridge.bridge_row_keys() do
        assert rows |> Enum.map(& &1.flows[key]) |> Enum.sum() == Map.fetch!(bridge.flows, key),
               "#{key} mismatch for #{club.id}"
      end
    end

    # May has no day rows in the feed — synthesised, still reconciling
    may = DB.day_rows("2026-05")
    assert length(may) == 36 * 31

    for club <- DB.clubs() do
      rows = Enum.filter(may, &(&1.club_id == club.id))
      bridge = Enum.find(DB.month_bridges(), &(&1.club_id == club.id and &1.month == "2026-05"))

      for key <- Bridge.bridge_row_keys() do
        assert rows |> Enum.map(& &1.flows[key]) |> Enum.sum() == Map.fetch!(bridge.flows, key)
      end

      assert Enum.map(rows, & &1.defaults_raised) |> Enum.sum() == bridge.defaults_raised
    end

    # forecast months have a full accrual too
    assert length(DB.day_rows("2026-10")) == 36 * 31
    assert DB.day_rows("2027-01") == []
  end

  test "billing runs cover every day of every month" do
    {:ok, _} = Ingest.load_file!(@snapshot)

    for meta <- DB.months() do
      runs = DB.billing_runs(meta.key)
      assert length(runs) == 36 * Bridge.days_in_month(meta), "runs short for #{meta.key}"
      assert Enum.all?(runs, &(&1.month == meta.key and &1.day == &1.date.day))
      assert Enum.all?(runs, &(&1.members_due >= 0))
    end

    # the fed days are used as-is; 31 Aug (after as-of) is filled in
    aug = DB.billing_runs("2026-08") |> Enum.filter(&(&1.club_id == "club-al-ain"))
    assert Enum.find(aug, &(&1.day == 31)).members_due > 0
  end

  test "finance targets exist for every club" do
    {:ok, _} = Ingest.load_file!(@snapshot)
    targets = DB.finance_targets()
    assert length(targets) == 36
    assert Enum.all?(targets, &(&1.new_sales_target >= 0 and is_integer(&1.total_target)))
  end

  test "the loader fills empty tables, refreshes on a newer snapshot, and leaves a newer feed alone" do
    assert GmBmd.Bridge.Loader.ensure_loaded() == :loaded
    assert GmBmd.Bridge.Loader.ensure_loaded() == :present

    # an older stamp in the tables → the bundled snapshot wins
    {:ok, _} = Ingest.load!(%{"generated_at" => "2000-01-01T00:00:00Z"})
    assert GmBmd.Bridge.Loader.ensure_loaded() == :loaded

    # a newer platform sync → left alone
    {:ok, _} = Ingest.load!(%{"generated_at" => "2999-01-01T00:00:00Z"})
    assert GmBmd.Bridge.Loader.ensure_loaded() == :present
  end

  test "re-ingesting upserts rather than duplicating, and replace wipes" do
    {:ok, _} = Ingest.load_file!(@snapshot)
    {:ok, _} = Ingest.load_file!(@snapshot)
    assert Ingest.counts().month_bridges == 36 * 6

    {:ok, _} =
      Ingest.load!(%{
        "replace" => true,
        "as_of" => "2026-08-15",
        "clubs" => [%{"id" => "club-x", "name" => "X"}],
        "month_bridges" => [
          %{
            "club_id" => "club-x",
            "month" => "2026-08",
            "opening" => 100,
            "flows" => %{"new_sales" => 10},
            "total" => 110,
            "net_growth" => 10
          }
        ]
      })

    assert Ingest.counts() == %{clubs: 1, month_bridges: 1, day_rows: 0, billing_runs: 0}
    assert DB.as_of() == ~D[2026-08-15]
    assert [%{id: "club-x", name: "X"}] = DB.clubs()
    assert length(DB.day_rows("2026-08")) == 31
  end
end
