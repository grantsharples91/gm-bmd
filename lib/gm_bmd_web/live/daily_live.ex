defmodule GmBmdWeb.DailyLive do
  @moduledoc """
  Daily transactions — expected vs actual total transactions for every day,
  how each KPI contributed, and what the days still to come need to deliver.
  Expected close always equals the outturn engine's close.
  """
  use GmBmdWeb, :live_view

  alias GmBmd.{Bridge, Daily, Gm, Outturn, Targets}
  alias GmBmdWeb.Charts
  alias GmBmdWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Daily Transactions", month: Bridge.current_month_key(), club_id: Gm.all_clubs())
     |> load()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    month = Map.get(params, "month", socket.assigns.month)

    month =
      if Enum.any?(Bridge.picker_months(), &(&1.key == month)), do: month, else: socket.assigns.month

    club_id = GmBmdWeb.Scope.from_params(params)
    {:noreply, socket |> assign(month: month, club_id: club_id) |> load()}
  end

  defp load(socket) do
    %{month: month, club_id: club_id} = socket.assigns
    month_label = (Bridge.month_meta(month) || %{label: month}).label
    resolved = Targets.resolve(month, club_id, month_label)

    outturn =
      Outturn.build(club_id, month, %{
        total_target: resolved.values.total,
        new_sales_target: resolved.values.new_sales
      })

    model =
      Daily.build(
        month,
        club_id,
        resolved.values,
        resolved.source,
        Outturn.daily_month_end_totals(outturn),
        outturn.base
      )

    assign(socket,
      resolved: resolved,
      model: model,
      current_month: Bridge.current_month_key(),
      variance_rag: Gm.rag_of(model.mtd_actual_total, model.mtd_forecast_total),
      tsv: Daily.tsv(model)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} identity={@identity} current_path={@current_path}>
      <div class="flex flex-col gap-3">
        <div class="flex flex-wrap items-center gap-2 rounded-xl bg-base-100 px-3 py-2 ring-1 ring-base-300">
          <.link
            navigate={~p"/"}
            class="inline-flex items-center gap-1 rounded-md bg-base-200 px-2 py-1.5 text-[11px] font-bold uppercase tracking-wide text-base-content hover:bg-base-300"
          >
            <.icon name="arrow-left" class="size-3" /> {gettext("Dashboard")}
          </.link>
          <h1 class="display-title text-sm">{gettext("Daily transactions")}</h1>
          <.month_club_filters
            month={@month}
            club_id={@club_id}
            months={Bridge.picker_months()}
            clubs={Bridge.clubs()}
            current_month={@current_month}
          />
          <span class="text-[11px] opacity-70">
            {Gm.scope_name(@club_id)}
            · day {@model.days_elapsed} of {@model.days_total}
          </span>
          <div class="ms-auto flex items-center gap-2">
            <.forecast_method model={@model} />
            <textarea id="tsv-payload" class="hidden" readonly>{@tsv}</textarea>
            <button
              id="tsv-copy"
              phx-hook="CopyPayload"
              data-source="tsv-payload"
              class="inline-flex items-center gap-1 rounded-md bg-primary px-2 py-1.5 text-[11px] font-bold uppercase tracking-wide text-primary-content"
            >
              <.icon name="copy" class="size-3" /> {gettext("Copy table")}
            </button>
          </div>
        </div>

        <p :if={@resolved.source != :approved} class="rounded-md bg-warning/15 px-3 py-2 text-[11px] font-semibold">
          {@resolved.note} Expected figures use last month's daily shape scaled to last month's total.
        </p>

        <div class="grid gap-2 sm:grid-cols-3">
          <.gm_tile label="MTD actual vs expected">
            <:right>
              <.rag_chip rag={@variance_rag}>{signed(@model.variance)}</.rag_chip>
            </:right>
            <p class="display-title text-xl leading-none tabular-nums">
              {signed(@model.mtd_actual_total)}
              <span class="text-muted">/ {signed(@model.mtd_forecast_total)}</span>
            </p>
            <p class="mt-0.5 text-[10px] text-muted">
              transactions to day {@model.days_elapsed} · MTD {num(@model.closing_actual)}
            </p>
          </.gm_tile>
          <.gm_tile label="Days left">
            <p class="display-title text-xl leading-none tabular-nums">{@model.days_left}</p>
            <p class="mt-0.5 text-[10px] text-muted">
              of {@model.days_total} · expected close {num(@model.month_forecast_close)}
            </p>
          </.gm_tile>
          <.gm_tile label="To hit month-end need">
            <p class="display-title text-xl leading-none tabular-nums">{signed(@model.need_per_day)} / day</p>
            <p class="mt-0.5 text-[10px] text-muted">
              target {num(@model.month_target)} · gap {signed(@model.month_target - @model.closing_actual)}
            </p>
          </.gm_tile>
        </div>

        <div class="rounded-lg bg-base-100 p-3 ring-1 ring-base-300">
          <p class="text-[10px] font-extrabold uppercase tracking-[0.12em] text-muted">
            Daily transactions — {@model.month_label} · each bar is that day's successful transactions by type; failed attempts, cancellations and refunds below the axis; expected faded
          </p>
          <Charts.daily_chart model={@model} />
        </div>

        <div :if={@model.reforecast != []} class="rounded-lg bg-base-100 p-3 ring-1 ring-base-300">
          <p class="text-[10px] font-extrabold uppercase tracking-[0.12em] text-muted">
            Remaining need — updated after yesterday's actual
          </p>
          <ul class="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-[11px]">
            <li :for={r <- @model.reforecast} class="font-semibold">
              {r.label}: need <span class="tabular-nums">{num(r.now)}</span>/day from today,
              <span class="text-muted">was {num(r.was)}</span>
            </li>
          </ul>
        </div>

        <div class="rounded-lg bg-base-100 p-3 ring-1 ring-base-300">
          <p class="text-[10px] font-extrabold uppercase tracking-[0.12em] text-muted">
            Day table — Billing run is the members due to bill that day (THOR schedule); Expected is the transactions we expect that day, all types. Past days show actuals with expected in grey underneath; future days are expected only
          </p>
          <div class="mt-2 overflow-x-auto">
            <table class="w-full min-w-[1060px] border-collapse text-xs">
              <thead>
                <tr class="text-[9px] uppercase tracking-wide text-muted">
                  <th class="px-1 py-1 text-start">Date</th>
                  <th class="px-1 py-1 text-start">Day</th>
                  <th class="px-1 py-1 text-end" title="Members due to bill that day — THOR's billing schedule">Billing run</th>
                  <th class="px-1 py-1 text-end" title="Transactions we expect that day, all types">Expected</th>
                  <th class="px-1 py-1 text-end">Actual</th>
                  <th class="px-1 py-1 text-end">Var</th>
                  <th :for={k <- Daily.daily_kpis()} class="px-1 py-1 text-end" title={k.label}>{k.short}</th>
                  <th class="px-1 py-1 text-end">Transactions</th>
                  <th class="px-1 py-1 text-end">MTD count</th>
                </tr>
              </thead>
              <tbody>
                <.day_row :for={r <- @model.rows} row={r} />
                <tr class="border-t-2 border-base-content text-[11px] font-bold">
                  <td class="px-1 py-1.5" colspan="3">MTD actual</td>
                  <td class="px-1 py-1.5 text-end tabular-nums text-muted">{signed(@model.mtd_forecast_total)}</td>
                  <td class="px-1 py-1.5 text-end tabular-nums">{signed(@model.mtd_actual_total)}</td>
                  <td class={["px-1 py-1.5 text-end tabular-nums", @model.variance < 0 && "text-negative"]}>
                    {signed(@model.variance)}
                  </td>
                  <td :for={c <- kpi_columns(@model)} class="px-1 py-1.5 text-end tabular-nums">
                    {num(c.mtd_actual)}
                  </td>
                  <td class="px-1 py-1.5 text-end tabular-nums">{signed(@model.mtd_actual_total)}</td>
                  <td class="px-1 py-1.5 text-end tabular-nums">{num(@model.closing_actual)}</td>
                </tr>
                <tr class="border-t border-base-300 text-[11px] text-muted">
                  <td class="px-1 py-1.5" colspan="6">Remaining expected · {@model.days_left} days</td>
                  <td :for={c <- kpi_columns(@model)} class="px-1 py-1.5 text-end tabular-nums">
                    {num(c.remaining_forecast)}
                  </td>
                  <td class="px-1 py-1.5 text-end tabular-nums">{signed(net_column(@model).remaining_forecast)}</td>
                  <td class="px-1 py-1.5 text-end tabular-nums">{num(@model.month_forecast_close)}</td>
                </tr>
                <tr class="border-t border-base-300 text-[11px] font-bold">
                  <td class="px-1 py-1.5" colspan="6">Month total vs target</td>
                  <td :for={c <- kpi_columns(@model)} class="px-1 py-1.5 text-end tabular-nums">
                    {num(c.month_total)}
                    <span class="block text-[9px] font-normal text-muted">
                      T {if c.target, do: num(c.target), else: "—"}
                    </span>
                  </td>
                  <td class="px-1 py-1.5 text-end tabular-nums">
                    {signed(@model.month_forecast_close - @model.opening)}
                  </td>
                  <td class="px-1 py-1.5 text-end tabular-nums">
                    {num(@model.month_forecast_close)}
                    <span class="block text-[9px] font-normal text-muted">T {num(@model.month_target)}</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp kpi_columns(model), do: Enum.filter(model.columns, &(&1.key != :net))
  defp net_column(model), do: Enum.find(model.columns, &(&1.key == :net))

  attr :row, :map, required: true

  defp day_row(assigns) do
    row = assigns.row
    src = row.actual || row.forecast
    variance = if row.actual, do: row.actual.net - row.forecast.net

    assigns = assign(assigns, src: src, variance: variance)

    ~H"""
    <tr class={[
      "border-t border-base-300",
      @row.today && "bg-steel-soft font-bold",
      !@row.past && "italic text-muted",
      @row.weekend && @row.past && !@row.today && "bg-base-200/40"
    ]}>
      <td class="px-1 py-1.5 tabular-nums">
        {@row.day}
        <span :if={@row.today} class="ms-1 text-[9px] uppercase tracking-wide">Today</span>
      </td>
      <td class="px-1 py-1.5">{@row.dow}</td>
      <td class="px-1 py-1.5 text-end tabular-nums">{num(@row.billing_due)}</td>
      <td class="px-1 py-1.5 text-end tabular-nums text-muted">{signed(@row.forecast.net)}</td>
      <td class="px-1 py-1.5 text-end tabular-nums">{if @row.actual, do: signed(@row.actual.net), else: "—"}</td>
      <td class={["px-1 py-1.5 text-end tabular-nums", @variance && @variance < 0 && "text-negative"]}>
        {if @variance, do: signed(@variance), else: "—"}
      </td>
      <td :for={k <- Daily.daily_kpis()} class="px-1 py-1.5 text-end tabular-nums">
        {num(@src[k.key])}
        <span :if={@row.past} class="block text-[9px] font-normal not-italic text-muted">
          {num(@row.forecast[k.key])}
        </span>
      </td>
      <td class={["px-1 py-1.5 text-end font-bold tabular-nums", @src.net < 0 && "text-negative"]}>
        {signed(@src.net)}
      </td>
      <td class="px-1 py-1.5 text-end tabular-nums">{num(@row.closing_position)}</td>
    </tr>
    """
  end

  attr :model, :map, required: true

  defp forecast_method(assigns) do
    ~H"""
    <.popover label={gettext("How expected is worked out")}>
      <p class="display-title mb-2 text-xs">How the expected figures are built</p>
      <ul class="list-disc space-y-1.5 ps-4 text-muted">
        <li>
          <strong class="text-base-content">Billing schedule.</strong>
          Recurring collected and defaults raised follow the billing runs: each day's share is the Billing run
          figure on the row (members due to bill that day), so expected recurring lands on run days and is
          zero on days with no run.
        </li>
        <li>
          <strong class="text-base-content">Remaining days.</strong>
          Sales-driven KPIs: (target − MTD actual) spread across the {@model.days_left} remaining days by
          day-of-week weight. Run-driven KPIs take their month-end total from the outturn engine, so this
          page and the outturn always close on the same number.
        </li>
        <li>
          <strong class="text-base-content">Past days.</strong>
          The expected figure shown is the original plan — the month-end target spread over every day with
          the same shape (billing schedule for run-driven KPIs, day-of-week weight for sales-driven).
        </li>
        <li>
          <strong class="text-base-content">Seasonality.</strong>
          Sales-driven KPIs only. UAE pattern: Sun–Thu normal, Fri quiet, Sat busiest, and an upfront spike
          over the last three days.
        </li>
        <li>
          <strong class="text-base-content">No approved targets.</strong>
          Last month's daily shape is used, scaled to last month's total.
        </li>
        <li>
          <strong class="text-base-content">Day-1 fixed block.</strong>
          Duplicates and prior-month cancellations fell out of the opening base on day 1 and are excluded from
          every day row — the opening position here is net of them.
        </li>
      </ul>
    </.popover>
    """
  end
end
