defmodule GmBmdWeb.Charts do
  @moduledoc "Inline-SVG charts — no charting dependency, themed via currentColor/tokens."
  use Phoenix.Component

  alias GmBmd.Daily

  @doc """
  Daily transaction movement: actual days stacked by KPI (positives above the
  axis, negatives below), forecast days rendered at 35% opacity, a net-movement
  marker per day, gridlines with values, and a hover callout per day showing
  the full make-up of the bar (`ChartTooltip` hook — no server round-trip).
  """
  attr :model, :map, required: true

  def daily_chart(assigns) do
    model = assigns.model
    w = 1000
    h = 240
    pad_l = 34
    pad_r = 6
    n = length(model.rows)
    slot = (w - pad_l - pad_r) / max(n, 1)
    bar = slot * 0.72

    pos_max =
      model.rows
      |> Enum.map(fn r ->
        k = r.actual || r.forecast
        k.new_sales + k.prior_recoveries + k.upfront
      end)
      |> Enum.max(fn -> 1 end)
      |> max(1)

    neg_max =
      model.rows
      |> Enum.map(fn r ->
        k = r.actual || r.forecast
        k.defaults_outstanding + k.cancel_within + k.refunds
      end)
      |> Enum.max(fn -> 1 end)
      |> max(1)

    axis_y = h * pos_max / (pos_max + neg_max)
    pos_scale = (axis_y - 12) / pos_max
    neg_scale = (h - axis_y - 12) / neg_max

    bars =
      model.rows
      |> Enum.with_index()
      |> Enum.map(fn {row, i} ->
        k = row.actual || row.forecast
        x0 = pad_l + i * slot
        x = x0 + (slot - bar) / 2

        {pos_rects, _} =
          Enum.map_reduce(Daily.chart_positive(), axis_y, fn seg, y ->
            value = Map.fetch!(k, seg.key)
            height = value * pos_scale
            {%{x: x, y: y - height, w: bar, h: height, colour: seg.colour, label: seg.label, value: value, day: row.day}, y - height}
          end)

        {neg_rects, _} =
          Enum.map_reduce(Daily.chart_negative(), axis_y, fn seg, y ->
            value = Map.fetch!(k, seg.key)
            height = value * neg_scale
            {%{x: x, y: y, w: bar, h: height, colour: seg.colour, label: seg.label, value: value, day: row.day}, y + height}
          end)

        net_y = if k.net >= 0, do: axis_y - k.net * pos_scale, else: axis_y + -k.net * neg_scale

        %{
          day: row.day,
          row: row,
          kpis: k,
          today: row.today,
          past: row.past,
          weekend: row.weekend,
          net: k.net,
          net_y: net_y,
          rects: pos_rects ++ neg_rects,
          x: x,
          x0: x0,
          bar_w: bar
        }
      end)

    pos_ticks = nice_ticks(pos_max, 3)
    neg_ticks = nice_ticks(neg_max, 2)

    assigns =
      assign(assigns,
        w: w,
        h: h,
        axis_y: axis_y,
        bars: bars,
        pad_l: pad_l,
        pad_r: pad_r,
        slot: slot,
        pos_ticks: Enum.map(pos_ticks, &{&1, axis_y - &1 * pos_scale}),
        neg_ticks: Enum.map(neg_ticks, &{&1, axis_y + &1 * neg_scale})
      )

    ~H"""
    <div id="daily-chart" phx-hook="ChartTooltip" class="relative">
      <svg viewBox={"0 0 #{@w} #{@h + 18}"} class="mt-2 w-full" role="img" aria-label="Daily transaction movement">
        <g :for={{v, y} <- @pos_ticks ++ @neg_ticks}>
          <line x1={@pad_l} y1={y} x2={@w - @pad_r} y2={y} class="stroke-base-300" stroke-width="0.5" stroke-dasharray="2 3" />
          <text x={@pad_l - 4} y={y + 3} text-anchor="end" class="fill-muted" font-size="8">
            {GmBmd.Format.num(v)}
          </text>
        </g>
        <line x1={@pad_l} y1={@axis_y} x2={@w - @pad_r} y2={@axis_y} class="stroke-base-content" stroke-width="1" opacity="0.5" />
        <text x={@pad_l - 4} y={@axis_y + 3} text-anchor="end" class="fill-muted" font-size="8">0</text>
        <g :for={db <- @bars}>
          <rect :if={db.weekend} x={db.x0} y="0" width={@slot} height={@h} class="fill-base-content" opacity="0.03" />
          <rect :if={db.today} x={db.x - 2} y="0" width={db.bar_w + 4} height={@h} class="fill-steel-soft" />
          <g opacity={if db.past, do: "1", else: "0.35"}>
            <rect :for={r <- db.rects} x={r.x} y={r.y} width={r.w} height={max(r.h, 0)} fill={r.colour} />
            <line
              x1={db.x - 1}
              y1={db.net_y}
              x2={db.x + db.bar_w + 1}
              y2={db.net_y}
              class="stroke-base-content"
              stroke-width="1.5"
            />
          </g>
          <text
            x={db.x + db.bar_w / 2}
            y={@h + 14}
            text-anchor="middle"
            class={[if(db.today, do: "fill-base-content font-bold", else: "fill-muted")]}
            font-size="9"
          >
            {db.day}
          </text>
          <rect
            x={db.x0}
            y="0"
            width={@slot}
            height={@h + 18}
            fill="transparent"
            class="cursor-crosshair hover:fill-base-content/5"
            data-day={db.day}
          />
        </g>
      </svg>
      <div class="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-[10px] text-muted">
        <span :for={seg <- Daily.chart_positive() ++ Daily.chart_negative()} class="inline-flex items-center gap-1.5">
          <span class="size-2 rounded-sm" style={"background:#{seg.colour}"}></span>
          {seg.label}
        </span>
        <span class="inline-flex items-center gap-1.5">
          <span class="inline-block h-[2px] w-3 bg-base-content"></span> Net movement
        </span>
        <span class="inline-flex items-center gap-1.5">
          <span class="size-2 rounded-sm bg-base-300 opacity-50"></span> Forecast (faded)
        </span>
        <span class="ms-auto">Hover a day for its make-up</span>
      </div>

      <div
        data-tip-box
        hidden
        phx-update="ignore"
        id="daily-chart-tip"
        class="pointer-events-none absolute z-20 w-64 rounded-lg border border-base-300 bg-base-100 p-3 text-[11px] shadow-lg"
      >
      </div>
      <template :for={db <- @bars} data-tip-for={db.day}>
        <.day_callout row={db.row} kpis={db.kpis} />
      </template>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :kpis, :map, required: true

  defp day_callout(assigns) do
    ~H"""
    <div class="mb-2 flex items-baseline justify-between gap-2 border-b border-base-300 pb-1.5">
      <span class="font-extrabold">
        {@row.dow} {Calendar.strftime(@row.date, "%-d %b")}
      </span>
      <span class={["text-[10px] font-bold uppercase tracking-wide", @row.past && "text-positive", !@row.past && "text-muted"]}>
        {cond do
          @row.today -> "Today · actual"
          @row.past -> "Actual"
          true -> "Forecast"
        end}
      </span>
    </div>
    <div class="space-y-0.5">
      <.callout_line :for={seg <- Daily.chart_positive()} label={seg.label} colour={seg.colour} value={Map.fetch!(@kpis, seg.key)} sign="+" />
      <.callout_line label="Defaults raised" colour="#B91C1C" value={@kpis.defaults_raised} sign="" muted />
      <.callout_line label="Defaults collected" colour="#059669" value={@kpis.defaults_collected} sign="" muted />
      <.callout_line label="Defaults outstanding" colour="#B91C1C" value={@kpis.defaults_outstanding} sign="−" />
      <.callout_line label="Cancellations in month" colour="#E06666" value={@kpis.cancel_within} sign="−" />
      <.callout_line label="Refunds" colour="#F3A6A6" value={@kpis.refunds} sign="−" />
    </div>
    <div class="mt-2 space-y-0.5 border-t border-base-300 pt-1.5">
      <div class="flex justify-between font-bold">
        <span>Net movement</span>
        <span class={["tabular-nums", @kpis.net < 0 && "text-negative"]}>{GmBmd.Format.signed(@kpis.net)}</span>
      </div>
      <div class="flex justify-between">
        <span class="text-muted">Position after this day</span>
        <span class="tabular-nums">{GmBmd.Format.num(@row.closing_position)}</span>
      </div>
      <div :if={@row.past and Map.get(@kpis, :transactions, 0) > 0} class="flex justify-between">
        <span class="text-muted">Transactions that day (THOR)</span>
        <span class="tabular-nums">{GmBmd.Format.num(@kpis.transactions)}</span>
      </div>
      <div class="flex justify-between">
        <span class="text-muted">Billing due</span>
        <span class="tabular-nums">{GmBmd.Format.num(@row.billing_due)}</span>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :colour, :string, required: true
  attr :value, :integer, required: true
  attr :sign, :string, required: true
  attr :muted, :boolean, default: false

  defp callout_line(assigns) do
    ~H"""
    <div class={["flex items-center justify-between gap-2", @muted && "text-muted"]}>
      <span class="inline-flex items-center gap-1.5">
        <span class="size-2 shrink-0 rounded-sm" style={"background:#{@colour}"}></span>
        {@label}
      </span>
      <span class="tabular-nums">{@sign}{GmBmd.Format.num(@value)}</span>
    </div>
    """
  end

  # 1–`count` evenly spaced "nice" tick values up to `max`.
  defp nice_ticks(top, count) do
    raw = top / count
    mag = :math.pow(10, :math.floor(:math.log10(max(raw, 1))))
    step = Enum.find([1, 2, 2.5, 5, 10], 10, fn m -> m * mag >= raw end) * mag
    step = if step < 1, do: 1, else: round(step)
    Stream.iterate(step, &(&1 + step)) |> Enum.take_while(&(&1 <= top)) |> Enum.take(count + 1)
  end

  @doc "Cumulative line chart: target (yellow), forecast (dashed grey), actual (navy)."
  attr :series, :list, required: true
  attr :height, :integer, default: 180
  attr :aed, :boolean, default: false

  def cumulative_chart(assigns) do
    w = 1000
    h = assigns.height
    pad = 8
    series = assigns.series
    n = max(length(series), 2)

    values =
      Enum.flat_map(series, fn p ->
        if assigns.aed,
          do: Enum.reject([p.actual_aed, p.target_aed], &is_nil/1),
          else: Enum.reject([p.actual, p.forecast, p.target], &is_nil/1)
      end)

    max_v = Enum.max([1 | values])
    x = fn i -> pad + i * (w - pad * 2) / (n - 1) end
    y = fn v -> h - pad - v / max_v * (h - pad * 2) end

    path = fn key ->
      series
      |> Enum.with_index()
      |> Enum.reject(fn {p, _i} -> is_nil(Map.fetch!(p, key)) end)
      |> Enum.map_join(" ", fn {p, i} ->
        prefix = if i == 0, do: "M", else: "L"
        "#{prefix}#{Float.round(x.(i), 1)},#{Float.round(y.(Map.fetch!(p, key)), 1)}"
      end)
      |> String.replace_prefix("L", "M")
    end

    assigns =
      if assigns.aed do
        assign(assigns, w: w, h: h, target_path: path.(:target_aed), actual_path: path.(:actual_aed), forecast_path: nil)
      else
        assign(assigns,
          w: w,
          h: h,
          target_path: path.(:target),
          forecast_path: path.(:forecast),
          actual_path: path.(:actual)
        )
      end

    ~H"""
    <svg viewBox={"0 0 #{@w} #{@h}"} class="w-full" role="img" aria-label="Cumulative chart">
      <path d={@target_path} fill="none" class="stroke-primary" stroke-width="2" />
      <path
        :if={@forecast_path}
        d={@forecast_path}
        fill="none"
        class="stroke-muted"
        stroke-width="2"
        stroke-dasharray="5 5"
      />
      <path :if={@actual_path != ""} d={@actual_path} fill="none" class="stroke-navy" stroke-width="2.5" />
    </svg>
    """
  end
end
