defmodule GmBmdWeb.OutturnLive do
  @moduledoc """
  Month-end position calculator: MTD position plus the remaining sales,
  upfronts and recoveries, minus defaults, refunds and cancellations, gives
  the month-end transaction position. Inputs prefill with the system forecast;
  defaults take a month-end OUTSTANDING total, not a still-to-come split.
  """
  use GmBmdWeb, :live_view

  alias GmBmd.{Bridge, Gm, Outturn, Targets}
  alias GmBmdWeb.Layouts

  @input_keys ~w(new_sales upfront recoveries defaults refunds cancel_within)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Month-End Position Calculator",
       month: Bridge.current_month_key(),
       club_id: Gm.all_clubs(),
       edits: %{},
       saved: false
     )
     |> load()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    month = Map.get(params, "month", socket.assigns.month)

    month =
      if Enum.any?(Bridge.picker_months(), &(&1.key == month)), do: month, else: socket.assigns.month

    club_id = GmBmdWeb.Scope.from_params(params)
    {:noreply, socket |> assign(month: month, club_id: club_id, edits: %{}, saved: false) |> load()}
  end

  def handle_event("edit", %{"key" => key, "value" => value}, socket) when key in @input_keys do
    edits =
      case Integer.parse(to_string(value)) do
        {n, _} -> Map.put(socket.assigns.edits, key, max(n, 0))
        :error -> socket.assigns.edits
      end

    {:noreply, socket |> assign(edits: edits, saved: false) |> load()}
  end

  def handle_event("reset-field", %{"key" => key}, socket) when key in @input_keys do
    {:noreply,
     socket |> assign(edits: Map.delete(socket.assigns.edits, key), saved: false) |> load()}
  end

  def handle_event("reset", _params, socket) do
    {:noreply, socket |> assign(edits: %{}, saved: false) |> load()}
  end

  def handle_event("save-forecast", _params, socket) do
    %{month: month, club_id: club_id, position: position, identity: identity} = socket.assigns
    Targets.save_gm_forecast(month, club_id, position, GmBmdWeb.Identity.display_name(identity))
    {:noreply, socket |> assign(saved: true) |> load()}
  end

  def handle_event("clear-forecast", _params, socket) do
    Targets.clear_gm_forecast(socket.assigns.month, socket.assigns.club_id)
    {:noreply, socket |> assign(saved: false) |> load()}
  end

  defp load(socket) do
    %{month: month, club_id: club_id, edits: edits} = socket.assigns
    month_label = (Bridge.month_meta(month) || %{label: month}).label
    resolved = Targets.resolve(month, club_id, month_label)

    ot =
      Outturn.build(club_id, month, %{
        total_target: resolved.values.total,
        new_sales_target: resolved.values.new_sales
      })

    row = fn key -> Enum.find(ot.rows, &(&1.key == key)) end
    df = Outturn.defaults_forecast(ot)

    system = %{
      "new_sales" => row.(:new_sales).remaining,
      "upfront" => row.(:upfront).remaining,
      "recoveries" => row.(:prior_default_collections).remaining + row.(:agency_collections).remaining,
      "defaults" => df.system_forecast,
      "refunds" => row.(:refunds).remaining,
      "cancel_within" => row.(:cancel_within).remaining
    }

    value_of = fn key -> Map.get(edits, key, system[key]) end
    per_day = fn n -> if ot.days_remaining > 0, do: round(n / ot.days_remaining), else: 0 end

    fields = [
      %{
        key: "new_sales",
        sign: 1,
        label: gettext("New sales"),
        mtd: row.(:new_sales).mtd,
        helper:
          "last month #{num(row.(:new_sales).last_month)} · target #{num(resolved.values.new_sales)} · run-rate #{per_day.(system["new_sales"])}/day"
      },
      %{
        key: "upfront",
        sign: 1,
        label: gettext("Upfronts"),
        mtd: row.(:upfront).mtd,
        helper:
          "last month #{num(row.(:upfront).last_month)} · target #{num(resolved.values.upfront)} · run-rate #{per_day.(system["upfront"])}/day"
      },
      %{
        key: "recoveries",
        sign: 1,
        label: gettext("Prior-month recoveries"),
        mtd: row.(:prior_default_collections).mtd + row.(:agency_collections).mtd,
        helper:
          "last month #{num(row.(:prior_default_collections).last_month + row.(:agency_collections).last_month)} · #{length(ot.billing_runs_left)} daily runs left · run-rate #{per_day.(system["recoveries"])}/day"
      },
      %{
        key: "refunds",
        sign: -1,
        label: gettext("Refunds"),
        mtd: row.(:refunds).mtd,
        helper:
          "#{num(ot.forecast_to_run)} to run × #{rate_str(ot.assumptions.refund_rate_pct)} · last month #{num(row.(:refunds).last_month)}"
      },
      %{
        key: "cancel_within",
        sign: -1,
        label: gettext("Cancellations within month"),
        mtd: row.(:cancel_within).mtd,
        helper:
          "#{num(ot.forecast_to_run)} to run × #{rate_str(ot.assumptions.cancel_within_rate_pct)} · last month #{num(row.(:cancel_within).last_month)}"
      }
    ]

    defaults_input = value_of.("defaults")

    position =
      Enum.reduce(fields, ot.mtd_total + ot.still_to_run, fn f, acc -> acc + f.sign * value_of.(f.key) end) -
        (defaults_input - df.mtd_outstanding)

    target = resolved.values.total
    saved_forecast = Targets.gm_forecast(month, club_id)

    assign(socket,
      month_label: month_label,
      current_month: Bridge.current_month_key(),
      resolved: resolved,
      ot: ot,
      df: df,
      system: system,
      fields: fields,
      values: Map.new(@input_keys, &{&1, value_of.(&1)}),
      defaults_input: defaults_input,
      dirty: Enum.any?(@input_keys, fn k -> value_of.(k) != system[k] end),
      position: position,
      target: target,
      gap: position - target,
      saved_forecast: saved_forecast,
      bar_pct: position |> Kernel./(max(target, 1)) |> Kernel.*(100) |> min(100) |> max(0)
    )
  end

  defp rate_str(v), do: "#{:erlang.float_to_binary(v / 1, decimals: 2)}%"

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
          <h1 class="display-title text-sm">{gettext("Month-end position calculator")}</h1>
          <.month_club_filters
            month={@month}
            club_id={@club_id}
            months={Bridge.picker_months()}
            clubs={Bridge.clubs()}
            current_month={@current_month}
          />
          <span class="ms-auto"><.how_calculated /></span>
        </div>

        <div class="rounded-lg bg-base-100 p-3 ring-1 ring-base-300 sm:p-4">
          <div class="grid gap-2 rounded-lg bg-base-200/60 p-3 text-xs sm:grid-cols-4">
            <div
              :for={
                {label, value, note} <- [
                  {"MTD position", num(@ot.mtd_total),
                   "#{Gm.scope_name(@club_id)} · #{@month_label}"},
                  {"Day", "#{@ot.days_elapsed} of #{@ot.days_total}", "month progress"},
                  {"Days left", "#{@ot.days_remaining}", "#{length(@ot.billing_runs_left)} billing runs left"},
                  {"Transactions still to run", num(@ot.forecast_to_run), "from the billing schedule"}
                ]
              }
            >
              <p class="text-[10px] font-bold uppercase tracking-wide text-muted">{label}</p>
              <p class="text-lg font-extrabold tabular-nums">{value}</p>
              <p class="text-[10px] text-muted">{note}</p>
            </div>
          </div>

          <div class="mt-3 grid gap-4 lg:grid-cols-[minmax(0,1fr)_320px]">
            <div class="flex flex-col divide-y divide-base-300">
              <div class="hidden gap-2 pb-1.5 text-[10px] font-bold uppercase tracking-wide text-muted sm:flex">
                <span class="min-w-[180px] flex-1">KPI</span>
                <span class="w-20 text-end">MTD so far</span>
                <span class="w-28 text-end">+ still to come</span>
                <span class="w-24 text-end">= month-end</span>
                <span class="w-7"></span>
              </div>
              <div :for={f <- @fields} class="flex flex-col gap-2 py-2.5 sm:flex-row sm:items-center">
                <div class="flex min-w-[180px] flex-1 items-center gap-2">
                  <span class={[
                    "flex size-6 shrink-0 items-center justify-center rounded-md text-sm font-extrabold",
                    f.sign == 1 && "bg-base-200 text-base-content",
                    f.sign == -1 && "bg-negative-soft text-negative"
                  ]}>
                    {if f.sign == 1, do: "+", else: "−"}
                  </span>
                  <div>
                    <p class="text-sm font-bold leading-tight">{f.label}</p>
                    <p class="text-[10px] leading-tight text-muted">{f.helper}</p>
                  </div>
                </div>
                <div class="flex items-center gap-2">
                  <div class="w-20 rounded-md bg-base-200/50 px-2 py-1.5 text-end ring-1 ring-base-300">
                    <span class="text-base font-extrabold tabular-nums">{num(f.mtd)}</span>
                  </div>
                  <form id={"edit-#{f.key}"} phx-change="edit" class="w-28">
                    <input type="hidden" name="key" value={f.key} />
                    <input
                      type="number"
                      name="value"
                      min="0"
                      value={@values[f.key]}
                      aria-label={"#{f.label} still to come"}
                      class="num-field"
                    />
                  </form>
                  <div class="w-24 rounded-md bg-navy px-2 py-1.5 text-end text-navy-content">
                    <span class="text-base font-extrabold tabular-nums">{num(f.mtd + @values[f.key])}</span>
                  </div>
                  <button
                    type="button"
                    phx-click="reset-field"
                    phx-value-key={f.key}
                    disabled={@values[f.key] == @system[f.key]}
                    aria-label={"Reset #{f.label}"}
                    title="Reset to system forecast"
                    class="rounded-md p-1.5 text-muted ring-1 ring-base-300 disabled:opacity-30"
                  >
                    <.icon name="rotate" class="size-3.5" />
                  </button>
                </div>
              </div>

              <div class="flex flex-col gap-2 py-2.5 sm:flex-row sm:items-center">
                <div class="flex min-w-[180px] flex-1 items-center gap-2">
                  <span class="flex size-6 shrink-0 items-center justify-center rounded-md bg-negative-soft text-sm font-extrabold text-negative">
                    −
                  </span>
                  <div>
                    <p class="text-sm font-bold leading-tight">
                      {gettext("Outstanding defaults forecast at month end")}
                    </p>
                    <p class="text-[10px] leading-tight text-muted">
                      current outstanding {num(@df.mtd_outstanding)} · system forecast {num(@df.system_forecast)}
                      · last month closed at {num(@df.last_month_closed)}
                    </p>
                  </div>
                </div>
                <div class="flex items-center gap-2">
                  <span class="w-20 text-end text-[10px] leading-tight text-muted">month-end total</span>
                  <form id="edit-defaults" phx-change="edit" class="w-28">
                    <input type="hidden" name="key" value="defaults" />
                    <input
                      type="number"
                      name="value"
                      min="0"
                      value={@defaults_input}
                      aria-label="Outstanding defaults forecast at month end"
                      class="num-field"
                    />
                  </form>
                  <span class="w-24 text-end text-[10px] leading-tight text-muted">
                    not a "still to come" split
                  </span>
                  <button
                    type="button"
                    phx-click="reset-field"
                    phx-value-key="defaults"
                    disabled={@defaults_input == @system["defaults"]}
                    aria-label="Reset outstanding defaults forecast"
                    class="rounded-md p-1.5 text-muted ring-1 ring-base-300 disabled:opacity-30"
                  >
                    <.icon name="rotate" class="size-3.5" />
                  </button>
                </div>
              </div>
            </div>

            <div class="flex flex-col gap-2 rounded-lg bg-navy p-3 text-navy-content">
              <p class="text-[10px] font-extrabold uppercase tracking-[0.12em] opacity-70">
                {gettext("Month-end position")}
              </p>
              <p class="text-4xl font-extrabold tabular-nums">{num(@position)}</p>
              <p class="text-xs opacity-80">
                vs target {num(@target)} ·
                <span class={["font-bold", @gap < 0 && "text-negative"]}>{signed(@gap)}</span>
                · net growth <span class="font-bold">{signed(@position - @ot.opening)}</span>
              </p>
              <div class="h-2 w-full overflow-hidden rounded-full bg-navy-content/15">
                <div
                  class={["h-full rounded-full", @gap < 0 && "bg-negative", @gap >= 0 && "bg-positive"]}
                  style={"width: #{@bar_pct}%"}
                >
                </div>
              </div>
              <p class="text-[10px] opacity-70">
                System forecast {num(@ot.base)}{if @dirty,
                  do: " · your inputs #{GmBmd.Format.signed(@position - @ot.base)}",
                  else: " · unchanged"}
              </p>
              <div class="mt-1 flex flex-wrap gap-2">
                <button
                  phx-click="reset"
                  class="inline-flex items-center gap-1 rounded-md bg-base-200 px-2 py-1.5 text-[11px] font-bold uppercase tracking-wide text-base-content hover:bg-base-300"
                >
                  <.icon name="rotate" class="size-3" /> Reset to system forecast
                </button>
                <button
                  phx-click="save-forecast"
                  class="inline-flex items-center gap-1 rounded-md bg-primary px-2 py-1.5 text-[11px] font-bold uppercase tracking-wide text-primary-content"
                >
                  <.icon :if={@saved} name="check" class="size-3" /> Save as my forecast
                </button>
              </div>
              <p :if={@saved_forecast} class="text-[10px] opacity-70">
                Saved GM forecast {num(@saved_forecast)} — the dashboard outturn line shows it next to the
                system number.
                <button phx-click="clear-forecast" class="font-bold underline">Clear</button>
              </p>
            </div>
          </div>

          <p class="mt-3 border-t border-base-300 pt-2 text-[11px] text-muted">
            Duplicates and prior-month cancellations already fell out of the opening base and are not part of
            the forecast.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp how_calculated(assigns) do
    ~H"""
    <.popover label={gettext("How this is calculated")}>
      <strong class="block text-xs">Month-end position</strong>
      MTD position + new sales + upfronts + prior-month recoveries − refunds − cancellations within month −
      defaults.
      <br /><br />
      For sales, upfronts, recoveries, refunds and cancellations you see <strong>MTD so far</strong>
      plus what is <strong>still to come</strong>
      (prefilled with the system forecast), which gives that KPI's month end.
      <br /><br />
      Defaults work differently — the defaults number is the
      <strong>total you expect to still be outstanding at month end</strong>. Your MTD position already
      deducts the outstanding balance to date, so only the difference between your month-end figure and
      today's outstanding is taken off. Leaving the system prefill in place leaves the position unchanged.
      <br /><br />
      The day-by-day view of the same forecast lives on
      <.link navigate={~p"/daily"} class="font-bold underline">Daily</.link>.
    </.popover>
    """
  end
end
