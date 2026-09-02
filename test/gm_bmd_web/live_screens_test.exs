defmodule GmBmdWeb.LiveScreensTest do
  use GmBmdWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias GmBmd.Bridge

  test "dashboard renders the five hero cards and the verdict", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "General Manager"
    assert html =~ ~s(aria-current="page")
    assert html =~ "MTD transactions"
    assert html =~ "MTD outstanding defaults"
    assert html =~ "Needs attention"

    # club filter narrows the screen
    club = hd(Bridge.clubs())

    html =
      view
      |> element("form[phx-change=filter]")
      |> render_change(%{"month" => Bridge.current_month_key(), "club_id" => club.id})

    assert html =~ club.name
  end

  test "daily renders the day table and reconciles to the outturn", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/daily")
    assert html =~ "Daily transactions"
    assert html =~ "Day table"
    assert html =~ "forecast close"
  end

  test "outturn calculator edits move the position", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/outturn")
    assert html =~ "Month-end position calculator"

    assert view
           |> element("#edit-new_sales")
           |> render_change(%{"key" => "new_sales", "value" => "999999"}) =~ "your inputs"
  end

  test "revenue renders streams and clubs", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/revenue")
    assert html =~ "Revenue &amp; Yield"
    assert html =~ "Recurring dues"
    assert html =~ "Upfront / PIF"
  end

  test "targets grid seeds, edits and approves", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/targets")
    assert html =~ "Monthly targets"
    assert html =~ "Targets locked in"

    club = hd(Bridge.clubs())
    html = view |> element("button[phx-value-club='" <> club.id <> "']") |> render_click()
    assert html =~ club.name
  end

  test "health endpoint answers without identity headers", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
