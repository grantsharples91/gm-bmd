defmodule GmBmdWeb.Charts do
  @moduledoc "Inline-SVG charts — no charting dependency, themed via currentColor/tokens."
  use Phoenix.Component

  alias GmBmd.Daily

  @doc """
  Daily transaction movement: actual days stacked by KPI (positives above the
  axis, negatives below), forecast days rendered at 35% opacity.
  """
  attr :model, :map, required: true

  def daily_chart(assigns) do
    model = assigns.model
    w = 1000
    h = 240
    pad = 6
    n = length(model.rows)
    slot = (w - pad * 2) / max(n, 1)
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
        x = pad + i * slot + (slot - bar) / 2

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

        %{
          day: row.day,
          today: row.today,
          past: row.past,
          net: k.net,
          rects: pos_rects ++ neg_rects,
          x: x,
          bar_w: bar
        }
      end)

    assigns =
      assign(assigns, w: w, h: h, axis_y: axis_y, bars: bars, pad: pad, slot: slot)

    ~H"""
    <div>
      <svg viewBox={"0 0 #{@w} #{@h + 18}"} class="mt-2 w-full" role="img" aria-label="Daily transaction movement">
        <line x1={@pad} y1={@axis_y} x2={@w - @pad} y2={@axis_y} class="stroke-base-300" stroke-width="1" />
        <g :for={db <- @bars} opacity={if db.past, do: "1", else: "0.35"}>
          <rect
            :if={db.today}
            x={db.x - 2}
            y="0"
            width={db.bar_w + 4}
            height={@h}
            class="fill-steel-soft"
          />
          <rect
            :for={r <- db.rects}
            x={r.x}
            y={r.y}
            width={r.w}
            height={max(r.h, 0)}
            fill={r.colour}
          >
            <title>{"Day #{r.day} · #{r.label}: #{GmBmd.Format.num(r.value)}"}</title>
          </rect>
          <text
            :if={rem(db.day, 2) == 1}
            x={db.x + db.bar_w / 2}
            y={@h + 14}
            text-anchor="middle"
            class="fill-muted"
            font-size="9"
          >
            {db.day}
          </text>
        </g>
      </svg>
      <div class="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-[10px] text-muted">
        <span :for={seg <- Daily.chart_positive() ++ Daily.chart_negative()} class="inline-flex items-center gap-1.5">
          <span class="size-2 rounded-sm" style={"background:#{seg.colour}"}></span>
          {seg.label}
        </span>
        <span class="inline-flex items-center gap-1.5">
          <span class="size-2 rounded-sm bg-base-300 opacity-50"></span> Forecast (faded)
        </span>
      </div>
    </div>
    """
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
