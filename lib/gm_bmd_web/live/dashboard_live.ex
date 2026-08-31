defmodule GmBmdWeb.DashboardLive do
  @moduledoc """
  GM Membership Analysis — the read-only collections dashboard: five hero
  cards, the plain-English verdict, needs-attention exceptions, yesterday +
  billing runs, and the tabbed bridge / by-club / position / revenue / outturn
  / activity panel.
  """
  use GmBmdWeb, :live_view

  alias GmBmd.{Activity, Bridge, Format, Gm, Outturn, Revenue, Rules, Targets}
  alias GmBmdWeb.Charts
  alias GmBmdWeb.Layouts

  @tabs ~w(bridge club position revenue outturn activity)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "GM Membership Analysis",
       month: Bridge.current_month_key(),
       club_id: Gm.all_clubs(),
       compare: :target,
       tab: "bridge",
       remaining: %{}
     )
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"month" => month, "club_id" => club_id}, socket) do
    month = if Enum.any?(Bridge.picker_months(), &(&1.key == month)), do: month, else: socket.assigns.month
    club_id = validate_club(club_id)
    {:noreply, socket |> assign(month: month, club_id: club_id, remaining: %{}) |> load()}
  end

  def handle_event("compare", %{"mode" => mode}, socket) do
    compare = if mode == "last_month", do: :last_month, else: :target
    {:noreply, socket |> assign(compare: compare) |> load()}
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in @tabs do
    {:noreply, assign(socket, tab: tab)}
  end

  def handle_event("attention-open", params, socket) do
    club_id = validate_club(Map.get(params, "club") || socket.assigns.club_id)
    tab = Map.get(params, "tab", socket.assigns.tab)
    tab = if tab in @tabs, do: tab, else: socket.assigns.tab
    {:noreply, socket |> assign(club_id: club_id, tab: tab, remaining: %{}) |> load()}
  end

  def handle_event("select-club", %{"club" => club_id}, socket) do
    current = socket.assigns.club_id
    next = if current == club_id, do: Gm.all_clubs(), else: validate_club(club_id)
    {:noreply, socket |> assign(club_id: next, remaining: %{}) |> load()}
  end

  def handle_event("remaining", %{"key" => key, "value" => value}, socket) do
    key = safe_row_key(key)

    remaining =
      case {key, Integer.parse(to_string(value))} do
        {nil, _} -> socket.assigns.remaining
        {key, {n, _}} -> Map.put(socket.assigns.remaining, key, max(n, 0))
        _ -> socket.assigns.remaining
      end

    {:noreply, socket |> assign(remaining: remaining) |> load()}
  end

  def handle_event("closing-set", %{"value" => raw} = params, socket) do
    %{month: month, club_id: club_id, identity: identity} = socket.assigns

    with false <- club_id == Gm.all_clubs(),
         {value, _} <- Integer.parse(String.replace(raw, ~r/[^\d]/, "")) do
      note = params |> Map.get("note", "") |> String.trim()
      by = GmBmdWeb.Identity.display_name(identity)
      GmBmd.Closings.set(club_id, month, value, by, if(note == "", do: nil, else: note))

      {:noreply,
       socket
       |> put_flash(:info, "#{socket.assigns.month_label} closing for #{Bridge.club_name(club_id)} set to #{Format.num(value)} — next month opens on it.")
       |> load()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Enter a whole number for the month-end closing.")}
    end
  end

  def handle_event("closing-clear", _params, socket) do
    %{month: month, club_id: club_id} = socket.assigns

    if club_id != Gm.all_clubs() do
      GmBmd.Closings.clear(club_id, month)
    end

    {:noreply, socket |> put_flash(:info, "Back to the system closing.") |> load()}
  end

  def handle_event("remaining-reset", _params, socket) do
    {:noreply, socket |> assign(remaining: %{}) |> load()}
  end

  defp validate_club(club_id) do
    if Enum.any?(Bridge.clubs(), &(&1.id == club_id)), do: club_id, else: Gm.all_clubs()
  end

  defp safe_row_key(key) do
    Enum.find(Bridge.bridge_row_keys(), &(to_string(&1) == key))
  end

  # ------------------------------------------------------------------- load

  defp load(socket) do
    %{month: month, club_id: club_id, compare: compare, remaining: remaining} = socket.assigns

    current = Bridge.current_month_key()
    through_day = if month == current, do: Bridge.today_day()
    month_label = (Bridge.month_meta(month) || %{label: month}).label

    totals = Gm.aggregate(Gm.rows_for(month, club_id, through_day))
    prev_month = Gm.previous_month_of(month)
    prev = Gm.aggregate(Gm.rows_for(prev_month, club_id, through_day || Bridge.today_day()))
    prev_bridge = Gm.bridge_snapshot(prev_month, club_id, through_day || Bridge.today_day())
    mtd_bridge = Gm.bridge_snapshot(month, club_id, through_day)
    full_bridge = Gm.bridge_snapshot(month, club_id)

    resolved = Targets.resolve(month, club_id, month_label)

    targets =
      Gm.finance_targets_for(club_id)
      |> Map.merge(%{
        total_target: resolved.values.total,
        new_sales_target: resolved.values.new_sales,
        upfront_target: resolved.values.upfront
      })

    target_override = %{total_target: resolved.values.total, new_sales_target: resolved.values.new_sales}

    resolve_club = fn id -> Targets.resolve(month, id, month_label).values end

    outturn_cache =
      [Gm.all_clubs() | Enum.map(Bridge.clubs(), & &1.id)]
      |> Map.new(fn id ->
        v = resolve_club.(id)
        {id, Outturn.build(id, month, %{total_target: v.total, new_sales_target: v.new_sales})}
      end)

    outturn_of = &Map.fetch!(outturn_cache, &1)
    base_outturn = outturn_of.(club_id)

    outturn =
      if remaining == %{},
        do: base_outturn,
        else: Outturn.build(club_id, month, target_override, %{}, remaining)

    series = Gm.cumulative_series(month, club_id, targets_for_series(targets))
    revenue = Revenue.view(month, club_id, through_day)
    prev_revenue = Revenue.view(prev_month, club_id, through_day || Bridge.today_day())

    on_pace = Rules.clubs_on_pace(month, resolve_club, outturn_of)
    attention = Rules.attention_items(month, resolve_club, outturn_of, club_id)
    yesterday = Rules.yesterday_vs_normal(month, club_id)
    next_run = Rules.next_billing_run(month, club_id)

    verdict =
      Rules.month_verdict(%{
        month_label: month_label,
        outturn_base: outturn.base,
        total_target: targets.total_target,
        attention: attention
      })

    sales_pace = Gm.expected_by_today(targets.new_sales_target, month)
    gm_forecast = Targets.gm_forecast(month, club_id)

    club_rows =
      Enum.map(Bridge.clubs(), fn c -> club_row(c.id, c.name, month, through_day, resolve_club, outturn_of) end)

    all_row = club_row(Gm.all_clubs(), "All clubs", month, through_day, resolve_club, outturn_of)

    events = Activity.todays_events(club_id)

    delta = fn actual, last_month, target, invert ->
      Gm.delta_for(actual, %{
        mode: compare,
        last_month: last_month,
        target: target,
        month: month,
        invert: invert
      })
    end

    assign(socket,
      current_month: current,
      through_day: through_day,
      month_label: month_label,
      prev_month_label: (Bridge.month_meta(prev_month) || %{label: prev_month}).label,
      closing: Gm.closing_for(month, club_id),
      prev_closing: Gm.closing_for(prev_month, club_id),
      totals: totals,
      prev: prev,
      prev_bridge: prev_bridge,
      mtd_bridge: mtd_bridge,
      full_bridge: full_bridge,
      resolved: resolved,
      targets: targets,
      outturn: outturn,
      base_outturn: base_outturn,
      series: series,
      revenue: revenue,
      prev_revenue: prev_revenue,
      on_pace: on_pace,
      attention: attention,
      yesterday: yesterday,
      next_run: next_run,
      verdict: verdict,
      sales_pace: sales_pace,
      gm_forecast: gm_forecast,
      club_rows: club_rows,
      all_row: all_row,
      events: events,
      delta: delta,
      csv: export_csv(month, through_day, resolve_club, outturn_of)
    )
  end

  defp targets_for_series(targets) do
    %{new_sales_target: targets.new_sales_target, revenue_target: targets.revenue_target}
  end

  defp club_row(id, name, month, through_day, resolve_club, outturn_of) do
    t = Gm.aggregate(Gm.rows_for(month, id, through_day))
    br = Gm.bridge_snapshot(month, id, through_day)
    tg = resolve_club.(id)
    ot = outturn_of.(id)
    expected = Gm.expected_by_today(tg.new_sales, month).expected

    %{
      id: id,
      name: name,
      total: br.total,
      new_sales: t.flows.new_sales,
      new_sales_target: tg.new_sales,
      new_sales_pace: expected,
      new_sales_behind: Gm.rag_of(t.flows.new_sales, expected) == :red,
      defaults: t.outstanding,
      defaults_raised: t.defaults_raised,
      defaults_recovered: t.defaults_recovered,
      recovery_pct: t.recovery_pct,
      prior_recoveries: t.flows.prior_default_collections,
      upfront: t.flows.upfront,
      net: br.net_growth,
      outturn: ot.base,
      outturn_target: ot.total_target,
      rag: Gm.rag_of(ot.base, ot.total_target),
      outstanding: t.outstanding,
      cancel_within: t.flows.cancel_within,
      cancel_prior: t.flows.cancel_prior,
      refunds: t.flows.refunds,
      duplicates: t.flows.duplicates,
      revenue: t.revenue,
      yield: t.yield
    }
  end

  defp export_csv(month, through_day, resolve_club, outturn_of) do
    headers = [
      "Club",
      "MTD transactions",
      "New sales",
      "New sales target",
      "Upfronts",
      "Defaults raised",
      "Defaults recovered",
      "Outstanding defaults",
      "Prior-month recoveries",
      "Cancellations within month",
      "Refunds",
      "Net growth",
      "Month-end outturn",
      "Transactions target",
      "Revenue collected (AED)"
    ]

    row = fn id, name ->
      t = Gm.aggregate(Gm.rows_for(month, id, through_day))
      br = Gm.bridge_snapshot(month, id, through_day)
      tg = resolve_club.(id)
      ot = outturn_of.(id)

      [
        ~s("#{name}"),
        br.total,
        t.flows.new_sales,
        tg.new_sales,
        t.flows.upfront,
        t.defaults_raised,
        t.defaults_recovered,
        t.outstanding,
        t.flows.prior_default_collections,
        t.flows.cancel_within,
        t.flows.refunds,
        br.net_growth,
        ot.base,
        ot.total_target,
        round(t.revenue)
      ]
      |> Enum.map_join(",", &to_string/1)
    end

    rows =
      [row.(Gm.all_clubs(), "All clubs") | Enum.map(Bridge.clubs(), &row.(&1.id, &1.name))]

    Enum.join([Enum.join(headers, ",") | rows], "\n")
  end

  # ----------------------------------------------------------------- render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} identity={@identity}>
      <div class="flex min-h-[620px] flex-col gap-4">
        <div class="flex flex-wrap items-center gap-3">
          <h1 class="display-title text-base">{gettext("GM Membership Analysis")}</h1>
          <.month_club_filters
            month={@month}
            club_id={@club_id}
            months={Bridge.picker_months()}
            clubs={Bridge.clubs()}
            current_month={@current_month}
          />
          <div class="flex h-8 items-stretch overflow-hidden rounded-md border border-base-300 bg-base-100">
            <button
              :for={{mode, label} <- [{"target", gettext("vs target")}, {"last_month", gettext("vs last month")}]}
              phx-click="compare"
              phx-value-mode={mode}
              class={[
                "px-3 text-[11px] font-bold transition",
                to_string(@compare) == mode && "bg-navy text-navy-content",
                to_string(@compare) != mode && "bg-transparent text-muted hover:bg-base-200"
              ]}
            >
              {label}
            </button>
          </div>
          <span class="ms-auto flex items-center gap-2 text-[11px] text-muted">
            <span
              class="hidden whitespace-nowrap lg:inline"
              title="On pace = new sales at or above 97% of the straight-line T2 pace for today AND forecast outturn at or above 98.5% of target."
            >
              {@on_pace.on_pace} of {@on_pace.total} clubs on pace
            </span>
            <span class="hidden whitespace-nowrap lg:inline">
              Revenue collected {aed_short(@totals.revenue)} · Yield {aed(@totals.yield)} / txn
            </span>
            Day {@sales_pace.elapsed} of {@sales_pace.total} · read-only
            <.how_to_read />
            <.definitions />
          </span>
        </div>

        <div class={[
          "flex flex-col gap-2 rounded-lg px-3 py-2.5 ring-1 sm:flex-row sm:items-start sm:gap-3",
          @verdict.status == :on && "bg-positive-soft ring-positive/40",
          @verdict.status == :watch && "bg-steel-soft ring-steel",
          @verdict.status == :off && "bg-negative-soft ring-negative/40"
        ]}>
          <div class="flex min-w-0 flex-1 items-start gap-2">
            <.icon
              name={if @verdict.status == :on, do: "trending-up", else: "alert"}
              class={[
                "mt-[2px] size-4",
                @verdict.status == :on && "text-positive",
                @verdict.status == :watch && "text-base-content",
                @verdict.status == :off && "text-negative"
              ]}
            />
            <p class="min-w-0 text-sm font-bold leading-snug">
              {@verdict.headline}
              <span :if={@verdict.drag} class="block text-[11px] font-semibold text-muted">
                {@verdict.drag}
              </span>
            </p>
          </div>
        </div>

        <div
          :if={@resolved.source == :draft}
          class="flex flex-wrap items-center gap-2 rounded-lg bg-base-200 px-3 py-2 text-xs font-semibold ring-1 ring-base-300"
        >
          {@month_label} targets not approved yet — comparing against draft.
          <.link navigate={~p"/targets"} class="font-extrabold uppercase tracking-wide underline">
            Review targets →
          </.link>
        </div>
        <p
          :if={@resolved.source != :draft}
          class="-mb-1 flex items-center gap-1.5 text-[10px] leading-none text-muted"
        >
          <.icon name="check" class="size-3 text-positive" />
          <span>{@resolved.note}</span>
          <.link navigate={~p"/targets"} class="font-bold underline hover:opacity-70">Targets</.link>
        </p>

        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2 md:grid-cols-3 xl:grid-cols-5">
          <.hero_card
            label={gettext("MTD transactions")}
            value={num(@mtd_bridge.total)}
            navigate={~p"/outturn"}
            hint="Every membership paying this month: opening base, plus new sales, upfronts and recoveries, minus cancellations, defaults and refunds."
            delta={mtd_delta(@compare, @mtd_bridge, @prev_bridge, @full_bridge)}
          >
            opening {num(@mtd_bridge.opening)} ·
            {if @gm_forecast,
              do: "GM forecast #{num(@gm_forecast)} · system #{num(@outturn.base)}",
              else: "outturn #{num(@outturn.base)} (#{signed(@outturn.net_growth)})"} ·
            <span class={["font-bold", @outturn.base < @targets.total_target && "text-negative"]}>
              need net {signed(need_net_per_day(@mtd_bridge.total, @targets.total_target, @month))}/day
            </span>
            to hit {num(@targets.total_target)} · Detail →
          </.hero_card>

          <.hero_card
            label={gettext("MTD new sales")}
            value={num(@totals.flows.new_sales)}
            hint="Brand-new memberships sold this month. For an upfront deal only the first payment counts here."
            delta={@delta.(@totals.flows.new_sales, @prev.flows.new_sales, @targets.new_sales_target, false).label}
          >
            of {num(@targets.new_sales_target)} target ·
            <.run_rate_line actual={@totals.flows.new_sales} target={@targets.new_sales_target} month={@month} />
          </.hero_card>

          <.hero_card
            label={gettext("MTD outstanding defaults")}
            value={num(@totals.outstanding)}
            tone={outstanding_tone(@totals)}
            hint="Failed payments this month not yet collected. Outstanding = defaults raised minus recovered — the number to shrink."
            delta={@delta.(@totals.outstanding, @prev.outstanding, @resolved.values.defaults, true).label}
          >
            of {num(@totals.defaults_raised)} defaulted · {num(@totals.defaults_recovered)} collected (<span class={[
              "font-bold",
              @totals.recovery_pct < Rules.gm_rules().recovery_floor && "text-negative"
            ]}>{pct(@totals.recovery_pct)}</span>)
            <:drill><.defaults_drilldown totals={@totals} /></:drill>
          </.hero_card>

          <.hero_card
            label={gettext("MTD prior recoveries")}
            value={num(@totals.flows.prior_default_collections)}
            hint="Payments collected this month against defaults raised in earlier months."
            delta={
              @delta.(
                @totals.flows.prior_default_collections,
                @prev.flows.prior_default_collections,
                @resolved.values.prior_recoveries,
                false
              ).label
            }
          >
            of {num(@resolved.values.prior_recoveries)} target ·
            <.run_rate_line
              actual={@totals.flows.prior_default_collections}
              target={@resolved.values.prior_recoveries}
              month={@month}
            />
          </.hero_card>

          <.hero_card
            label={gettext("MTD upfronts")}
            value={num(@totals.flows.upfront)}
            hint="The remaining paid-in-advance payments on an upfront contract — a 12-month upfront is 1 new sale plus 11 upfront transactions."
            delta={@delta.(@totals.flows.upfront, @prev.flows.upfront, @targets.upfront_target, false).label}
          >
            of {num(@targets.upfront_target)} target ·
            <.run_rate_line actual={@totals.flows.upfront} target={@targets.upfront_target} month={@month} />
          </.hero_card>
        </div>

        <.attention_panel attention={@attention} club_id={@club_id} />

        <div :if={@yesterday || @next_run} class="grid grid-cols-1 gap-3 lg:grid-cols-2">
          <div :if={@yesterday} class="panel p-3">
            <div class="mb-2 flex items-center gap-1.5 text-[11px] font-bold uppercase tracking-wide text-muted">
              <.icon name="history" class="size-3.5" /> Yesterday ({@yesterday.label})
            </div>
            <div class="grid grid-cols-2 gap-x-4 sm:grid-cols-3">
              <div
                :for={
                  {label, value} <- [
                    {"Sales", @yesterday.yesterday.new_sales},
                    {"Upfronts", @yesterday.yesterday.upfront},
                    {"Defaults raised", @yesterday.yesterday.defaults_raised},
                    {"Recovered", @yesterday.yesterday.defaults_recovered},
                    {"Cancellations", @yesterday.yesterday.cancellations},
                    {"Refunds", @yesterday.yesterday.refunds}
                  ]
                }
                class="flex items-baseline justify-between gap-2 border-b border-base-300/60 py-1.5"
              >
                <span class="text-[11px] text-muted">{label}</span>
                <span class="text-sm font-bold">{num(value)}</span>
              </div>
            </div>
          </div>
          <div :if={@next_run} class="panel p-3">
            <div class="mb-2 flex items-center gap-1.5 text-[11px] font-bold uppercase tracking-wide text-muted">
              <.icon name="calendar" class="size-3.5" /> Daily billing runs
            </div>
            <div class="grid grid-cols-2 gap-x-4">
              <div
                :for={
                  {label, value} <- [
                    {"Next run (#{@next_run.label})", "#{num(@next_run.due)} due"},
                    {"Runs left this month", "#{length(@outturn.billing_runs_left)}"},
                    {"Average due per run", "≈ #{num(@outturn.avg_due_left)}"},
                    {"Last run collected", pct(@next_run.last_collected_pct)}
                  ]
                }
                class="flex items-baseline justify-between gap-2 border-b border-base-300/60 py-1.5"
              >
                <span class="text-[11px] text-muted">{label}</span>
                <span class="text-sm font-bold">{value}</span>
              </div>
            </div>
          </div>
        </div>

        <div class="flex min-h-[300px] flex-1 flex-col rounded-xl bg-base-100 ring-1 ring-base-300">
          <div class="flex items-center gap-1 overflow-x-auto border-b border-base-300 px-3 pt-2">
            <button
              :for={
                {key, label} <- [
                  {"bridge", gettext("Membership bridge")},
                  {"club", gettext("By club")},
                  {"position", gettext("MTD position by club")},
                  {"revenue", gettext("Revenue & yield")},
                  {"outturn", gettext("Outturn")},
                  {"activity", "#{gettext("Today's activity")} · #{length(@events)} txns"}
                ]
              }
              phx-click="tab"
              phx-value-tab={key}
              class={[
                "-mb-px shrink-0 whitespace-nowrap border-b-2 px-3 py-2 text-[11px] font-extrabold uppercase tracking-[0.12em]",
                @tab == key && "border-base-content text-base-content",
                @tab != key && "border-transparent text-muted hover:text-base-content"
              ]}
            >
              {label}
            </button>
            <.link
              :if={@tab in ["outturn", "bridge"]}
              navigate={~p"/outturn"}
              class="ms-auto inline-flex shrink-0 items-center gap-1 py-2 ps-3 text-[11px] font-bold uppercase tracking-wide hover:opacity-70"
            >
              Assumptions →
            </.link>
          </div>

          <div class="flex min-h-0 flex-1 flex-col p-4">
            <.bridge_tab
              :if={@tab == "bridge"}
              mtd={@mtd_bridge}
              full={@full_bridge}
              totals={@totals}
              full_totals={Gm.aggregate(Gm.rows_for(@month, @club_id))}
              closing={@closing}
              prev_closing={@prev_closing}
              club_id={@club_id}
              month_label={@month_label}
              prev_month_label={@prev_month_label}
            />
            <.club_table :if={@tab == "club"} rows={@club_rows} all={@all_row} selected={@club_id} />
            <.position_strip :if={@tab == "position"} rows={if(@club_id == "all", do: @club_rows, else: Enum.filter(@club_rows, &(&1.id == @club_id)))} selected={@club_id} />
            <.revenue_tab :if={@tab == "revenue"} revenue={@revenue} prev_revenue={@prev_revenue} totals={@totals} month={@month} />
            <.outturn_tab
              :if={@tab == "outturn"}
              outturn={@outturn}
              base_outturn={@base_outturn}
              remaining={@remaining}
              series={@series}
            />
            <.activity_tab :if={@tab == "activity"} events={@events} />
          </div>
        </div>

        <div class="panel flex flex-col gap-2 px-3 py-2 print:hidden sm:flex-row sm:items-center sm:justify-between">
          <p class="min-w-0 text-[11px] leading-[16px] text-muted">
            <span class="font-extrabold uppercase tracking-wide text-base-content">
              MTD collections report
            </span>
            — full position as at day {@sales_pace.elapsed} of {@sales_pace.total}, one row per club plus an all-clubs line.
          </p>
          <div class="flex shrink-0 items-center gap-2">
            <textarea id="csv-payload" class="hidden" readonly>{@csv}</textarea>
            <button
              id="csv-download"
              phx-hook="DownloadPayload"
              data-source="csv-payload"
              data-filename={"gymnation-membership-#{@month}.csv"}
              class="inline-flex h-8 items-center gap-1.5 rounded-md bg-primary px-3 text-[11px] font-extrabold uppercase tracking-wide text-primary-content hover:opacity-90"
            >
              <.icon name="download" class="size-3.5" /> Download CSV
            </button>
            <button
              id="print-page"
              phx-hook="PrintPage"
              class="inline-flex h-8 items-center gap-1.5 rounded-md border border-base-300 bg-base-100 px-3 text-[11px] font-bold hover:bg-base-200"
            >
              <.icon name="printer" class="size-3.5" /> Print
            </button>
          </div>
        </div>

        <p class="text-[11px] text-muted">
          Bridge check · opening {num(@mtd_bridge.opening)} → total transactions {num(@mtd_bridge.total)} MTD ({signed(
            @mtd_bridge.net_growth
          )}) · full-month {num(@full_bridge.total)} ({signed(@full_bridge.net_growth)}).
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp mtd_delta(compare, mtd, prev_bridge, full_bridge) do
    base = if compare == :last_month, do: prev_bridge.total, else: full_bridge.total
    p = if base != 0, do: (mtd.total - base) / base, else: 0.0
    tail = if compare == :last_month, do: "vs last month same day", else: "vs month-end outturn"
    "#{Format.signed_pct(p)} #{tail}"
  end

  defp need_net_per_day(actual, target, month) do
    rr = Rules.run_rate(actual, target, month)
    if rr.days_left > 0, do: (target - actual) / rr.days_left, else: 0.0
  end

  defp outstanding_tone(totals) do
    if totals.defaults_raised > 0 and
         totals.outstanding / totals.defaults_raised > Rules.gm_rules().outstanding_ceiling,
       do: "red",
       else: nil
  end

  # ------------------------------------------------------------- components

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil
  attr :delta, :string, default: nil
  attr :navigate, :string, default: nil
  attr :tone, :string, default: nil
  slot :inner_block, required: true
  slot :drill

  defp hero_card(assigns) do
    ~H"""
    <div class="relative flex min-h-[150px] min-w-0 flex-col rounded-xl bg-base-100 px-4 pb-3 pt-3 text-start ring-1 ring-base-300 transition hover:ring-2 hover:ring-primary">
      <p class="flex items-center gap-1 text-[11px] font-extrabold uppercase leading-[13px] tracking-[0.12em] text-muted">
        <span>{@label}</span>
        <span :if={@hint} title={@hint} class="inline-flex"><.icon name="info" class="size-3 opacity-60" /></span>
      </p>
      <p class={[
        "display-title mt-1.5 whitespace-nowrap text-[28px] leading-none tabular-nums sm:text-[32px]",
        @tone == "red" && "text-negative"
      ]}>
        <%= if @navigate do %>
          <.link navigate={@navigate}>{@value}</.link>
        <% else %>
          {@value}
        <% end %>
      </p>
      <p :if={@delta} class="mt-1.5 text-[10px] leading-[13px] text-muted">{@delta}</p>
      <p class="mt-1 pb-1 text-[11px] leading-[14px] text-muted">{render_slot(@inner_block)}</p>
      <details :if={@drill != []} class="pop mt-auto">
        <summary class="cursor-pointer text-[10px] font-bold uppercase tracking-wide text-muted">
          Drill down
        </summary>
        <div class="absolute start-0 top-full z-30 mt-1 w-[420px] max-w-[92vw] rounded-lg bg-base-100 p-3 shadow-lg ring-1 ring-base-300">
          {render_slot(@drill)}
        </div>
      </details>
    </div>
    """
  end

  attr :actual, :integer, required: true
  attr :target, :integer, required: true
  attr :month, :string, required: true

  defp run_rate_line(assigns) do
    assigns = assign(assigns, :rr, Rules.run_rate(assigns.actual, assigns.target, assigns.month))

    ~H"""
    <span>
      {@rr.days_left} days left ·
      <span class={["font-bold", @rr.hot && "text-negative", !@rr.hot && "text-base-content"]}>
        need {num(@rr.need_per_day)}/day
      </span>
      (avg {num(@rr.avg_per_day)})
    </span>
    """
  end

  attr :attention, :list, required: true
  attr :club_id, :string, required: true

  defp attention_panel(assigns) do
    ~H"""
    <section class="rounded-xl bg-base-100 ring-1 ring-base-300">
      <div class="flex items-center gap-2 border-b border-base-300 px-4 py-2">
        <h2 class="text-[12px] font-extrabold uppercase tracking-wide">{gettext("Needs attention")}</h2>
        <span class="text-[11px] text-muted">
          · {if @club_id == "all", do: "All clubs", else: Bridge.club_name(@club_id)}
        </span>
        <span class="text-[11px] text-muted">
          {length(@attention)} item{if length(@attention) == 1, do: "", else: "s"}
        </span>
      </div>
      <p class="border-b border-base-300 bg-base-200/60 px-4 py-1.5 text-[11px] text-muted">
        Only exceptions show here, worst first. Click a line to open the club and the figure behind it.
      </p>
      <ul class="divide-y divide-base-300">
        <li :for={item <- @attention}>
          <button
            type="button"
            phx-click="attention-open"
            phx-value-club={item.club_id}
            phx-value-tab={attention_tab(item.tab)}
            class="flex w-full items-start gap-2.5 px-4 py-2 text-start text-[12px] leading-[17px] hover:bg-base-200/70"
          >
            <span class={[
              "mt-1.5 size-2 shrink-0 rounded-full",
              item.tone == :red && "bg-negative",
              item.tone == :amber && "bg-steel",
              item.tone == :grey && "bg-muted",
              item.tone == :green && "bg-positive"
            ]}>
            </span>
            <span class="min-w-0">
              {item.text}
              <span :if={Rules.attention_action(item.id)} class="mt-0.5 block text-[11px] text-muted">
                → {Rules.attention_action(item.id)}
              </span>
            </span>
            <span class="ms-auto hidden shrink-0 text-[11px] text-muted sm:inline">Open →</span>
          </button>
        </li>
      </ul>
    </section>
    """
  end

  defp attention_tab(nil), do: nil
  defp attention_tab(tab), do: to_string(tab)

  attr :mtd, :map, required: true
  attr :full, :map, required: true
  attr :totals, :map, required: true
  attr :full_totals, :map, required: true
  attr :closing, :map, required: true
  attr :prev_closing, :map, required: true
  attr :club_id, :string, required: true
  attr :month_label, :string, required: true
  attr :prev_month_label, :string, required: true

  defp bridge_tab(assigns) do
    assigns =
      assign(assigns, :scale, assigns.full.lines |> Enum.map(& &1.value) |> Enum.max(fn -> 1 end) |> max(1))

    ~H"""
    <div class="min-w-0">
      <div class="flex items-baseline justify-between text-[10px] font-extrabold uppercase tracking-[0.12em] text-muted">
        <span>{gettext("Membership bridge")}</span>
        <span class="shrink-0">MTD <span class="ms-3 sm:ms-6">Full month</span></span>
      </div>
      <div class="mt-2 space-y-1">
        <.bridge_row
          label="Opening transactions"
          note={opening_note(@prev_month_label, @prev_closing)}
          mtd={@mtd.opening}
          full={@full.opening}
          bold
        />
        <.bridge_row
          :for={{line, i} <- Enum.with_index(@full.lines)}
          label={bridge_label(line, @full_totals)}
          note={bridge_note(line, @totals)}
          mtd={Enum.at(@mtd.lines, i).value}
          full={line.value}
          negative={line.sign == -1}
          bar_pct={line.value / @scale}
          zero_dash={line.key == :agency_collections}
          fixed={line.fixed}
        />
        <.bridge_row label="= Total transactions" mtd={@mtd.total} full={@full.total} bold />
        <.bridge_row
          label="Net growth"
          note="Total transactions minus opening — negative mid-month is normal while the day-1 fixed rows are already deducted in full"
          mtd={@mtd.net_growth}
          full={@full.net_growth}
          bold
          signed_value
        />
      </div>
      <p class="mt-2 flex items-start gap-1 text-[10px] text-muted">
        <.icon name="lock" class="mt-[2px] size-2.5" />
        Duplicates from prior month and cancellations actioned prior month are fixed for the month — known on day 1, so MTD equals the full month and the forecast equals the actual.
      </p>
      <.closing_block closing={@closing} club_id={@club_id} month_label={@month_label} />
    </div>
    """
  end

  defp opening_note(prev_label, %{overrides: []}), do: "= #{prev_label} closing (system)"

  defp opening_note(prev_label, %{overrides: [o]}),
    do: "= #{prev_label} closing set by #{o.set_by || "manager"}"

  defp opening_note(prev_label, %{overrides: overrides}),
    do: "= #{prev_label} closing · #{length(overrides)} clubs set by managers"

  attr :closing, :map, required: true
  attr :club_id, :string, required: true
  attr :month_label, :string, required: true

  # Month-end closing — what next month opens on. A single club can be
  # corrected by hand; the all-clubs view only reports.
  defp closing_block(assigns) do
    override = List.first(assigns.closing.overrides)
    assigns = assign(assigns, override: override, single: assigns.club_id != Gm.all_clubs())

    ~H"""
    <div class="mt-3 rounded-lg border border-base-300 bg-base-200/40 p-3 print:hidden" id="closing-block">
      <div class="flex flex-wrap items-baseline justify-between gap-2">
        <span class="text-[10px] font-extrabold uppercase tracking-[0.12em] text-muted">
          Month-end closing · carried into next month's opening
        </span>
        <span class="text-sm font-bold tabular-nums">{Format.num(@closing.value)}</span>
      </div>

      <p :if={!@single} class="mt-1 text-[11px] text-muted">
        Sum of {@closing.clubs} clubs · system computed {Format.num(@closing.computed)}
        <span :if={@closing.overrides != []}>
          · {length(@closing.overrides)} set by managers
        </span>
        · pick a club to set its closing by hand.
      </p>

      <div :if={@single}>
        <p :if={@override} class="mt-1 text-[11px]">
          <span class="font-bold text-primary">Set by {@override.set_by || "manager"}</span>
          <span class="text-muted">
            · {if @override.set_at, do: Calendar.strftime(@override.set_at, "%-d %b %H:%M"), else: ""}
            · system computed {Format.num(@closing.computed)}
            <span :if={@override.note}> · “{@override.note}”</span>
          </span>
        </p>
        <p :if={!@override} class="mt-1 text-[11px] text-muted">
          System figure — the bridge total above. If it is wrong, set the true closing here and {@month_label}'s
          successor opens on your number.
        </p>
        <form phx-submit="closing-set" class="mt-2 flex flex-wrap items-center gap-2">
          <input
            type="text"
            name="value"
            inputmode="numeric"
            value={@override && @override.value}
            placeholder={Format.num(@closing.computed)}
            class="h-8 w-32 rounded-md border border-base-300 bg-base-100 px-2 text-xs tabular-nums"
            aria-label="Month-end closing"
          />
          <input
            type="text"
            name="note"
            value={@override && @override.note}
            placeholder="Reason (optional)"
            class="h-8 min-w-0 flex-1 rounded-md border border-base-300 bg-base-100 px-2 text-xs"
          />
          <button type="submit" class="h-8 rounded-md bg-navy px-3 text-[11px] font-bold text-navy-content">
            Set closing
          </button>
          <button
            :if={@override}
            type="button"
            phx-click="closing-clear"
            data-confirm="Drop the manager closing and go back to the system figure?"
            class="h-8 rounded-md border border-base-300 px-3 text-[11px] font-bold text-muted hover:bg-base-200"
          >
            Use system
          </button>
        </form>
      </div>
    </div>
    """
  end

  defp bridge_label(%{key: :defaults} = line, full_totals),
    do: "− #{line.label} (total defaulted #{Format.num(full_totals.defaults_raised)})"

  defp bridge_label(line, _),
    do: "#{if line.sign == -1, do: "−", else: "+"} #{line.label}"

  defp bridge_note(%{key: :defaults}, totals),
    do:
      "collected #{Format.num(totals.defaults_recovered)} · outstanding #{Format.num(totals.outstanding)} MTD — the deduction is the outstanding balance"

  defp bridge_note(_line, _totals), do: nil

  attr :label, :string, required: true
  attr :mtd, :integer, required: true
  attr :full, :integer, required: true
  attr :negative, :boolean, default: false
  attr :bold, :boolean, default: false
  attr :bar_pct, :float, default: nil
  attr :signed_value, :boolean, default: false
  attr :zero_dash, :boolean, default: false
  attr :fixed, :boolean, default: false
  attr :note, :string, default: nil

  defp bridge_row(assigns) do
    ~H"""
    <div class={["flex items-center gap-3 border-t border-base-300 py-1 text-xs", @bold && "font-bold"]}>
      <span class="min-w-0 flex-1">
        <span class="block truncate">
          {@label}
          <span :if={@fixed} class="ms-1 whitespace-nowrap text-[10px] font-normal text-muted">
            <.icon name="lock" class="size-2.5" /> set on day 1
          </span>
        </span>
        <span :if={@note} class="block truncate text-[10px] font-normal text-muted">{@note}</span>
      </span>
      <span :if={@bar_pct} class="hidden h-1.5 w-24 shrink-0 rounded-full bg-base-200 md:block">
        <span
          class={["block h-1.5 rounded-full", @negative && "bg-negative", !@negative && "bg-navy"]}
          style={"width: #{min(max(@bar_pct, 0), 1) * 100}%"}
        >
        </span>
      </span>
      <span :if={!@bar_pct} class="hidden w-24 shrink-0 md:block"></span>
      <span class={["w-12 shrink-0 text-end tabular-nums sm:w-16", @negative && "text-negative"]}>
        {bridge_value(@mtd, @zero_dash, @signed_value)}
      </span>
      <span class="w-12 shrink-0 text-end tabular-nums text-muted sm:w-16">
        {bridge_value(@full, @zero_dash, @signed_value)}
      </span>
    </div>
    """
  end

  defp bridge_value(0, true, _signed), do: "—"
  defp bridge_value(v, _zero_dash, true), do: Format.signed(v)
  defp bridge_value(v, _zero_dash, _signed), do: Format.num(v)

  attr :rows, :list, required: true
  attr :all, :map, required: true
  attr :selected, :string, required: true

  defp club_table(assigns) do
    ~H"""
    <div class="min-w-0">
      <p class="mb-2 text-xs text-muted">Click a row to filter the whole screen to that club.</p>
      <div class="overflow-x-auto">
        <table class="w-full min-w-[900px] border-collapse text-xs">
          <thead>
            <tr class="text-[11px] font-extrabold uppercase tracking-[0.08em] text-muted">
              <th class="px-3 pb-2 text-start">Club</th>
              <th class="px-3 pb-2 text-end">MTD transactions</th>
              <th class="px-3 pb-2 text-end">New sales (mtd/tgt)</th>
              <th class="px-3 pb-2 text-end">O/S Defaults</th>
              <th class="px-3 pb-2 text-end">Prior recoveries</th>
              <th class="px-3 pb-2 text-end">Upfronts</th>
              <th class="px-3 pb-2 text-end">Net</th>
              <th class="px-3 pb-2 text-end">Outturn</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={r <- @rows}
              phx-click="select-club"
              phx-value-club={r.id}
              class={[
                "h-10 cursor-pointer border-t border-base-300 hover:bg-base-200/60",
                @selected == r.id && "bg-navy-soft"
              ]}
            >
              <td class="truncate px-3 font-bold">{r.name}</td>
              <.club_cells r={r} />
            </tr>
            <tr class="h-10 border-t-2 border-base-content bg-base-200/60 font-bold">
              <td class="px-3">All clubs</td>
              <.club_cells r={@all} />
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :r, :map, required: true

  defp club_cells(assigns) do
    ~H"""
    <td class="px-3 text-end tabular-nums">{num(@r.total)}</td>
    <td class="px-3 text-end tabular-nums">{num(@r.new_sales)}/{num(@r.new_sales_target)}</td>
    <td
      class="px-3 text-end font-bold tabular-nums"
      title={"#{num(@r.defaults)} outstanding of #{num(@r.defaults_raised)} defaulted · #{num(@r.defaults_recovered)} collected (#{pct(@r.recovery_pct)})"}
    >
      <span class={[
        @r.defaults_raised > 0 && @r.defaults / @r.defaults_raised > 0.4 && "text-negative"
      ]}>
        {num(@r.defaults)}
      </span>
      <span class="ms-1 text-[10px] font-normal text-muted">
        of {num(@r.defaults_raised)} · {pct(if @r.defaults_raised > 0, do: @r.defaults / @r.defaults_raised, else: 0)}
      </span>
    </td>
    <td class="px-3 text-end tabular-nums">{num(@r.prior_recoveries)}</td>
    <td class="px-3 text-end tabular-nums">{num(@r.upfront)}</td>
    <td class={["px-3 text-end tabular-nums", @r.net < 0 && "text-negative"]}>{signed(@r.net)}</td>
    <td class="px-3 text-end tabular-nums">{num(@r.outturn)}</td>
    """
  end

  attr :rows, :list, required: true
  attr :selected, :string, required: true

  defp position_strip(assigns) do
    ~H"""
    <div class="panel p-3">
      <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
        <p class="text-[11px] font-extrabold uppercase tracking-wide">
          {if @selected == "all", do: "MTD position by club", else: "MTD position"}
        </p>
        <p class="text-[10px] text-muted">
          {if @selected == "all",
            do: "Click a club to scope the whole screen to it",
            else: "Click to return to all clubs"}
        </p>
      </div>
      <div class="grid grid-cols-1 gap-2 sm:grid-cols-2 xl:grid-cols-3">
        <button
          :for={r <- @rows}
          phx-click="select-club"
          phx-value-club={r.id}
          class={[
            "rounded-lg border p-2.5 text-start transition hover:bg-base-200",
            @selected == r.id && "border-navy bg-navy-soft",
            @selected != r.id && "border-base-300 bg-base-100"
          ]}
        >
          <div class="flex items-center gap-2">
            <span class={[
              "size-2 shrink-0 rounded-full",
              r.rag == :green && "bg-positive",
              r.rag == :amber && "bg-steel",
              r.rag == :red && "bg-negative"
            ]}>
            </span>
            <span class="min-w-0 truncate text-xs font-extrabold uppercase tracking-wide">{r.name}</span>
            <span class="ms-auto shrink-0 text-sm font-extrabold tabular-nums">{num(r.total)}</span>
          </div>
          <dl class="mt-2 space-y-1">
            <div
              :for={
                {label, value, bad} <- [
                  {"Outturn vs target", "#{num(r.outturn)} / #{num(r.outturn_target)}", r.outturn < r.outturn_target},
                  {"New sales vs pace", "#{num(r.new_sales)} / #{num(r.new_sales_pace)}", r.new_sales < r.new_sales_pace},
                  {"O/S defaults", num(r.outstanding), false},
                  {"Revenue collected", aed_short(r.revenue), false}
                ]
              }
              class="flex items-baseline justify-between gap-2"
            >
              <dt class="text-[10px] text-muted">{label}</dt>
              <dd class={["text-[11px] font-bold tabular-nums", bad && "text-negative"]}>{value}</dd>
            </div>
          </dl>
        </button>
      </div>
    </div>
    """
  end

  attr :revenue, :map, required: true
  attr :prev_revenue, :map, required: true
  attr :totals, :map, required: true
  attr :month, :string, required: true

  defp revenue_tab(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 flex-col gap-3">
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <.hero_card
          label={gettext("MTD revenue collected")}
          value={aed_short(@revenue.net)}
          navigate={~p"/revenue"}
          hint="Cash actually collected this month across all streams, net of refunds."
          delta={"#{signed_pct(if @prev_revenue.net != 0, do: (@revenue.net - @prev_revenue.net) / @prev_revenue.net, else: 0.0)} vs last month same day"}
        >
          of {aed_short(@revenue.revenue_target)} target ({pct(
            if @revenue.revenue_target > 0, do: @revenue.net / @revenue.revenue_target, else: 0
          )}) · top stream {hd(@revenue.streams).label} {pct(hd(@revenue.streams).share)} · By stream →
        </.hero_card>
        <.hero_card
          label={gettext("MTD yield")}
          value={"#{aed(@revenue.yield)} / txn"}
          navigate={~p"/revenue"}
          hint="Average AED collected per collecting transaction."
          delta={"#{signed_pct(if @prev_revenue.yield != 0, do: (@revenue.yield - @prev_revenue.yield) / @prev_revenue.yield, else: 0.0)} vs last month same day"}
        >
          {num(@totals.collected_transactions)} collecting transactions · last month {aed(@prev_revenue.yield)} · Yield by stream →
        </.hero_card>
      </div>
      <p class="text-[11px] text-muted">
        <.link navigate={~p"/revenue"} class="font-bold text-base-content underline hover:opacity-70">
          Revenue &amp; yield detail →
        </.link>
        every stream, refunds and yield by club.
      </p>
    </div>
    """
  end

  attr :outturn, :map, required: true
  attr :base_outturn, :map, required: true
  attr :remaining, :map, required: true
  attr :series, :list, required: true

  defp outturn_tab(assigns) do
    ~H"""
    <div class="grid min-h-0 flex-1 gap-5 xl:grid-cols-2">
      <div class="flex min-h-0 min-w-0 flex-col">
        <p class="text-sm text-muted">
          Forecast total transactions {num(@outturn.base)} ({signed(@outturn.net_growth)} net growth) ·
          {num(@outturn.new_sales_mtd)} new sales so far, {num(@outturn.new_sales_forecast)} forecast against a
          {num(@outturn.new_sales_target)} target · {length(@outturn.billing_runs_left)} daily billing runs left ·
          ≈ {num(@outturn.avg_due_left)}/day due.
        </p>
        <p class="text-[11px] text-muted/80">
          ≈ {aed_short(@outturn.revenue_forecast)} · {aed_short(@outturn.revenue_mtd)} collected so far
        </p>
        <p class="mt-3 text-[10px] font-extrabold uppercase tracking-[0.12em] text-muted">
          Cumulative new membership sales
        </p>
        <Charts.cumulative_chart series={@series} height={180} />
        <p class="mt-1 text-[10px] font-extrabold uppercase tracking-[0.12em] text-muted">
          Secondary — cumulative AED
        </p>
        <Charts.cumulative_chart series={@series} height={80} aed />
      </div>
      <div class="min-w-0">
        <div class="mb-2 grid grid-cols-3 gap-2 rounded-md bg-base-200/60 p-2 text-center">
          <div
            :for={
              {label, value, muted} <- [
                {"Ran", num(@outturn.ran), false},
                {"Forecast to run", num(@outturn.forecast_to_run), true},
                {"Total to run", num(@outturn.total_to_run), false}
              ]
            }
          >
            <p class="text-[9px] font-bold uppercase tracking-wide text-muted">{label}</p>
            <p class={["text-sm font-extrabold tabular-nums", muted && "text-muted"]}>{value}</p>
          </div>
        </div>
        <div class="flex items-baseline justify-between gap-2">
          <p class="text-[10px] font-extrabold uppercase tracking-[0.12em] text-muted">
            Assumptions — remaining {@outturn.days_remaining} day{if @outturn.days_remaining == 1, do: "", else: "s"}
          </p>
          <button
            :if={@remaining != %{}}
            phx-click="remaining-reset"
            class="text-[10px] font-bold uppercase tracking-wide hover:opacity-70"
          >
            Reset
          </button>
        </div>
        <table class="mt-2 w-full border-collapse text-[10px] sm:text-[11px]">
          <thead>
            <tr class="text-[9px] uppercase tracking-wide text-muted">
              <th class="px-1 py-1 text-start">Bridge row</th>
              <th class="w-12 px-1 py-1 text-end">MTD</th>
              <th class="w-20 px-1 py-1 text-end">Rem.</th>
              <th class="w-14 px-1 py-1 text-end">Fcst</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={r <- @outturn.rows} class="border-t border-base-300">
              <td class="truncate px-1 py-1" title={r.label}>
                {if r.sign == -1, do: "−", else: "+"} {r.short}
                <.icon :if={r.fixed} name="lock" class="ms-1 size-2.5 text-muted" />
              </td>
              <td class="px-1 py-1 text-end tabular-nums">{num(r.mtd)}</td>
              <td class="px-1 py-1 text-end">
                <span :if={r.driver == :fixed} class="text-muted">fixed</span>
                <span :if={r.driver == :run} class="tabular-nums text-muted" title={r.formula}>
                  {num(r.remaining)} <span class="text-[9px] uppercase">run</span>
                </span>
                <form
                  :if={r.driver == :sales}
                  phx-change="remaining"
                  phx-value-key={r.key}
                  class="inline-block w-20"
                >
                  <input type="hidden" name="key" value={r.key} />
                  <input
                    type="number"
                    name="value"
                    min="0"
                    value={r.remaining}
                    aria-label={"#{r.label} remaining"}
                    class="num-field w-20 py-0.5 text-[11px]"
                  />
                </form>
              </td>
              <td class={["px-1 py-1 text-end font-bold tabular-nums", r.sign == -1 && "text-negative"]}>
                {num(r.forecast)}
              </td>
            </tr>
            <tr class="border-t-2 border-base-content font-bold">
              <td class="px-1 py-1">Total transactions</td>
              <td class="px-1 py-1 text-end tabular-nums">{num(@outturn.mtd_total)}</td>
              <td class="px-1 py-1 text-end text-[10px] uppercase text-muted">
                {if @remaining != %{}, do: "was #{num(@base_outturn.base)}", else: "run-rate"}
              </td>
              <td class="px-1 py-1 text-end tabular-nums">{num(@outturn.base)}</td>
            </tr>
          </tbody>
        </table>
        <p class="mt-2 text-[10px] text-muted">
          Best {num(@outturn.best)} · base {num(@outturn.base)} · worst {num(@outturn.worst)} transactions
          (default rate ±25%, sales ±5%). Rows marked <strong>run</strong> are computed from the
          {num(@outturn.forecast_to_run)} transactions still to run × an observed rate — edit those rates on the
          outturn detail. Locked rows are fixed for the month.
          <.link navigate={~p"/outturn"} class="font-bold text-base-content hover:opacity-70">
            Full outturn detail →
          </.link>
        </p>
      </div>
    </div>
    """
  end

  attr :events, :list, required: true

  defp activity_tab(assigns) do
    groups =
      assigns.events
      |> Enum.group_by(fn e -> "#{String.pad_leading(to_string(e.at.hour), 2, "0")}:00" end)
      |> Enum.sort_by(fn {hour, _} -> hour end, :desc)

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <div class="min-h-0 flex-1 overflow-y-auto pe-1">
      <p class="mb-2 text-[10px] text-muted">
        Placeholder feed — replaced by the live transaction stream when the database plug-in lands.
      </p>
      <div class="grid grid-cols-1 gap-x-6 sm:grid-cols-2 xl:grid-cols-3">
        <div :for={{hour, list} <- @groups} class="mb-3">
          <div class="flex items-baseline justify-between border-b border-base-300 pb-1">
            <span class="text-[11px] font-extrabold uppercase tracking-[0.12em] text-muted">
              {hour} · {length(list)} events
            </span>
            <span class="text-[11px] font-semibold tabular-nums text-muted">
              {signed(Enum.sum(Enum.map(list, &Activity.signed_amount/1)))}
            </span>
          </div>
          <div
            :for={e <- list}
            title={"#{e.member_full_name} · #{Activity.event_meta()[e.kind].label}#{if e.reason, do: " · #{e.reason}"} · #{e.club_name}"}
            class="flex w-full items-center gap-2 py-1 text-start"
          >
            <span class={[
              "size-2 shrink-0 rounded-full",
              Activity.event_meta()[e.kind].tone == :green && "bg-positive",
              Activity.event_meta()[e.kind].tone == :red && "bg-negative",
              Activity.event_meta()[e.kind].tone == :yellow && "bg-primary",
              Activity.event_meta()[e.kind].tone == :grey && "bg-muted"
            ]}>
            </span>
            <span class="truncate text-xs font-semibold">{e.member_name}</span>
            <span class="truncate text-[11px] text-muted">
              {e.stream} · {e.club_name |> String.split(" ") |> hd()}
            </span>
            <span class={[
              "ms-auto shrink-0 text-xs font-bold tabular-nums",
              Activity.signed_amount(e) < 0 && "text-negative"
            ]}>
              {signed(Activity.signed_amount(e))}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :totals, :map, required: true

  defp defaults_drilldown(assigns) do
    assigns = assign(assigns, :b, Gm.defaults_breakdown(assigns.totals))

    ~H"""
    <div>
      <p class="text-[11px] font-extrabold uppercase tracking-[0.14em] text-muted">
        Defaults this month · transactions and AED
      </p>
      <table class="mt-2 w-full border-collapse text-xs">
        <tbody>
          <tr
            :for={
              {label, count, share, aed_v, red} <- [
                {"Total defaulted", @b.raised, 1.0, @b.aed.raised, false},
                {"Collected", @b.recovered, @b.recovered_pct, @b.aed.recovered, false},
                {"Outstanding", @b.outstanding, @b.outstanding_pct, @b.aed.outstanding, true}
              ]
            }
            class="border-t border-base-300"
          >
            <td class="py-1.5 font-bold">{label}</td>
            <td class={["py-1.5 text-end font-bold tabular-nums", red && "text-negative"]}>{num(count)}</td>
            <td class="py-1.5 text-end tabular-nums text-muted">{pct(share)}</td>
            <td class="py-1.5 text-end tabular-nums">{aed(aed_v)}</td>
          </tr>
        </tbody>
      </table>
      <p class="mt-2 text-[11px] text-muted">
        Headline KPI is <strong>outstanding</strong> = defaulted − collected. AED = transactions × yield.
      </p>
      <div class="mt-3">
        <p class="text-[11px] font-extrabold uppercase tracking-[0.14em] text-muted">
          Defaults funnel · this month · transactions
        </p>
        <div class="mt-2 space-y-2">
          <div :for={step <- Gm.defaults_funnel(@totals)} class="flex items-center gap-2">
            <span class="w-[84px] shrink-0 text-[10px] font-bold uppercase leading-tight text-muted">
              {step.label}
            </span>
            <div class="h-2 min-w-0 flex-1 rounded-full bg-base-200">
              <div
                class={["h-2 rounded-full", step.key == :outstanding && "bg-negative", step.key != :outstanding && "bg-navy"]}
                style={"width: #{step.count / max(Enum.max_by(Gm.defaults_funnel(@totals), & &1.count).count, 1) * 100}%"}
              >
              </div>
            </div>
            <span class="w-[92px] shrink-0 text-end text-[11px] font-bold tabular-nums">
              {num(step.count)} txns
            </span>
          </div>
        </div>
        <p class="mt-2 text-[11px] text-muted">
          Recovery % = recovered ÷ raised. Retried = defaults × 94% retry rate.
        </p>
      </div>
    </div>
    """
  end

  defp how_to_read(assigns) do
    ~H"""
    <.popover label={gettext("How to read this screen")}>
      <p class="display-title mb-2 text-xs">How to read this screen</p>
      <ul class="space-y-1.5 text-muted">
        <li>
          <strong class="text-base-content">The five cards</strong>
          are the month-to-date position: transactions, new sales, outstanding defaults, prior recoveries and upfronts.
        </li>
        <li>
          <strong class="text-base-content">vs target</strong>
          compares against the approved T2 target pro-rated to today; <strong class="text-base-content">vs last month</strong>
          compares the same day last month.
        </li>
        <li>
          <strong class="text-base-content">Outturn</strong>
          is the forecast month-end close — the same number on every screen, including the Daily view.
        </li>
        <li>
          <strong class="text-base-content">Needs attention</strong>
          only fires on material gaps, so an empty list means the month is behaving.
        </li>
        <li>Read-only. Figures come from the THOR feed (see the badge in the header for how current they are); the tabs below break the same month down by club and by driver.</li>
      </ul>
    </.popover>
    """
  end

  defp definitions(assigns) do
    ~H"""
    <.popover label={gettext("Definitions")}>
      <p class="display-title mb-2 text-xs">How every number is calculated</p>
      <dl class="space-y-2">
        <div :for={{term, body} <- definitions_list()}>
          <dt class="text-xs font-bold">{term}</dt>
          <dd class="leading-snug text-muted">{body}</dd>
        </div>
      </dl>
    </.popover>
    """
  end

  defp definitions_list do
    [
      {"Everything is transactions",
       "Every KPI is a count of transactions, not members. Revenue (AED) is secondary. The monthly membership-analysis bridge is the single source of truth."},
      {"Opening transactions",
       "The transaction base the club started the month with — last month's closing total. A stock, never pro-rated for MTD."},
      {"Fixed rows (locked)",
       "Duplicates from prior month and cancellations actioned prior month are fixed at the start of the month: known on day 1, no daily accrual, no run-rate — the outturn takes them as-is."},
      {"New membership sales",
       "Memberships sold this month on a recurring plan. The headline number the sales targets are set against."},
      {"Upfront membership transactions",
       "The contract's remaining instalments taken in advance — a 12-month upfront deal = 1 new sale + 11 upfront transactions at the normal instalment value."},
      {"Defaults",
       "Members who paid last month, were due this month, and failed. Headline KPI is OUTSTANDING defaults (defaulted − collected); the bridge deducts the outstanding balance only."},
      {"Total transactions / net growth",
       "Total = opening − duplicates + new sales + prior collections + upfront + agency − cancellations − defaults − refunds. Net growth = total − opening."},
      {"Month-end outturn",
       "The same bridge projected to month end: run-driven rows are transactions still to run × an observed rate; sales rows run-rate; fixed rows taken as-is."},
      {"Daily billing runs",
       "Recurring billing runs EVERY calendar day — heavier at month start, Fri quiet, Sat busy. Transactions ran = the daily runs to date."},
      {"Yield", "Revenue collected ÷ collecting transactions (AED per transaction) — the one metric that leads with money."}
    ]
  end
end
