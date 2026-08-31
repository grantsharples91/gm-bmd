defmodule GmBmdWeb.ThorFeedTest do
  @moduledoc "End to end on the real feed: ingest the THOR snapshot, render every screen."

  use GmBmdWeb.ConnCase, async: false

  alias GmBmd.Bridge
  alias GmBmd.Bridge.{DB, Ingest}

  @snapshot Path.expand("../../priv/bridge/thor_snapshot.json", __DIR__)

  setup do
    previous = Application.get_env(:gm_bmd, :bridge_source)
    Application.put_env(:gm_bmd, :bridge_source, DB)
    DB.reload()
    {:ok, _} = Ingest.load_file!(@snapshot)

    on_exit(fn ->
      Application.put_env(:gm_bmd, :bridge_source, previous)
      DB.reload()
    end)

    :ok
  end

  test "all 36 clubs flow through the bridge and MTD stops at the as-of date" do
    assert length(Bridge.clubs()) == 36
    assert Bridge.as_of() == ~D[2026-08-30]
    assert Bridge.current_month_key() in Enum.map(Bridge.months(), & &1.key)

    # the feed stops at 30 Aug, so the dashboard stays on August, MTD to day 30
    assert Bridge.current_month_key() == "2026-08"
    assert Bridge.today_day() == 30
    assert Enum.map(Bridge.picker_months(), & &1.key) == ~w(2026-08 2026-07 2026-06 2026-05 2026-04 2026-03)
  end

  test "every screen renders on the feed", %{conn: conn} do
    for path <- ["/", "/daily", "/outturn", "/revenue", "/targets"] do
      {:ok, _view, html} = live(conn, path)
      assert html =~ "THOR · data to", "feed badge missing on #{path}"
      assert html =~ "Motor City"
    end
  end

  test "MTD transactions is THOR's count and the bridge reconciles to it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> element("form[phx-change=filter]")
      |> render_change(%{"month" => "2026-08", "club_id" => "club-motor-city"})

    assert html =~ "7,365"
    assert html =~ "Still to run / unreconciled"

    snap = GmBmd.Gm.bridge_snapshot("2026-08", "club-motor-city", 30)
    assert snap.total == 7365
    assert snap.opening == Bridge.bridge_for("club-motor-city", "2026-07").closing
    assert List.last(snap.lines).key == :reconcile
    assert snap.projected + snap.reconcile == snap.total

    # outturn starts from the count and adds what is still to come
    ot = GmBmd.Outturn.build("club-motor-city", "2026-08", %{total_target: 7500, new_sales_target: 500})
    assert ot.mtd_total == 7365
    assert ot.base == Enum.reduce(ot.rows, ot.mtd_total, fn r, acc -> acc + r.sign * r.remaining end)
  end

  test "daily chart carries a hover callout per day with the bar's make-up", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/daily")
    assert html =~ ~s(id="daily-chart")
    assert html =~ ~s(phx-hook="ChartTooltip")
    assert html =~ ~s(data-tip-for="1")
    assert html =~ ~s(data-tip-for="31")
    assert html =~ "Position after this day"
    assert html =~ "Transactions that day (THOR)"
    assert html =~ "Net movement"
  end

  test "dashboard narrows to a club that only exists in the feed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    club = Enum.find(Bridge.clubs(), &(&1.name == "Al Faisaliyyah Ladies"))

    html =
      view
      |> element("form[phx-change=filter]")
      |> render_change(%{"month" => Bridge.current_month_key(), "club_id" => club.id})

    assert html =~ "Al Faisaliyyah Ladies"
  end

  test "a manager sets the month-end closing from the bridge tab", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> element("form[phx-change=filter]")
      |> render_change(%{"month" => "2026-07", "club_id" => "club-al-ain"})

    assert html =~ "Month-end closing"
    assert html =~ "Set closing"

    html = view |> element("#closing-block form") |> render_submit(%{"value" => "6,000", "note" => "desk count"})
    assert html =~ "Set by test"
    assert html =~ "desk count"
    assert GmBmd.Closings.get("club-al-ain", "2026-07").value == 6000

    # August now opens on the manager's figure
    html =
      view
      |> element("form[phx-change=filter]")
      |> render_change(%{"month" => "2026-08", "club_id" => "club-al-ain"})

    assert html =~ "July 2026 closing set by test"
    assert Bridge.bridge_for("club-al-ain", "2026-08").opening == 6000

    # and can be dropped again
    view
    |> element("form[phx-change=filter]")
    |> render_change(%{"month" => "2026-07", "club_id" => "club-al-ain"})

    html = view |> element("#closing-block button[phx-click=closing-clear]") |> render_click()
    refute html =~ "Set by test"
    assert GmBmd.Closings.get("club-al-ain", "2026-07") == nil
  end

  test "ingest status and the authenticated endpoint", %{conn: conn} do
    conn = get(conn, ~p"/api/ingest/status")
    body = json_response(conn, 200)
    assert body["loaded"] == true
    assert body["counts"]["clubs"] == 36
    assert body["provenance"]["as_of"] == "2026-08-30"

    # disabled without a token
    conn = build_conn() |> put_req_header("content-type", "application/json") |> post(~p"/api/ingest", "{}")
    assert json_response(conn, 503)

    Application.put_env(:gm_bmd, :ingest_token, "secret")
    on_exit(fn -> Application.delete_env(:gm_bmd, :ingest_token) end)

    conn = build_conn() |> put_req_header("content-type", "application/json") |> post(~p"/api/ingest", "{}")
    assert json_response(conn, 401)

    payload = %{
      "as_of" => "2026-08-31",
      "month_bridges" => [
        %{
          "club_id" => "club-al-ain",
          "month" => "2026-03",
          "opening" => 5000,
          "flows" => %{"new_sales" => 100},
          "total" => 5100,
          "net_growth" => 100
        }
      ]
    }

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> post(~p"/api/ingest", Jason.encode!(payload))

    body = json_response(conn, 200)
    assert body["ok"] == true
    assert body["counts"]["month_bridges"] == 1
    assert Bridge.as_of() == ~D[2026-08-31]
    # the first month keeps the opening the feed sent; the next opens on its closing
    assert Bridge.bridge_for("club-al-ain", "2026-03").opening == 5000
    assert Bridge.bridge_for("club-al-ain", "2026-04").opening == 5100
  end
end
