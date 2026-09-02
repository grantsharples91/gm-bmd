defmodule GmBmdWeb.RevenueLive do
  @moduledoc """
  Revenue & yield — MTD revenue broken down by stream (recurring dues, new
  sales, upfront/PIF, recoveries, refunds) with per-club revenue and AED per
  transaction. Read-only; revenue = transactions × unit AED.
  """
  use GmBmdWeb, :live_view

  alias GmBmd.{Bridge, Gm, Revenue}
  alias GmBmdWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Revenue & Yield", month: Bridge.current_month_key(), club_id: Gm.all_clubs())
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

  def handle_event("select-club", %{"club" => club_id}, socket) do
    club_id = GmBmdWeb.Scope.from_ids(club_id)
    {:noreply, socket |> assign(club_id: club_id) |> load()}
  end

  defp load(socket) do
    %{month: month, club_id: club_id} = socket.assigns
    current = Bridge.current_month_key()
    through_day = if month == current, do: Bridge.today_day()
    prev_month = Gm.previous_month_of(month)
    view = Revenue.view(month, club_id, through_day)
    prev = Revenue.view(prev_month, club_id, through_day || Bridge.today_day())

    assign(socket,
      current_month: current,
      view: view,
      prev: prev,
      by_club: Revenue.by_club(month, through_day),
      rev_delta: if(prev.net != 0, do: (view.net - prev.net) / prev.net, else: 0.0),
      yield_delta: if(prev.yield != 0, do: (view.yield - prev.yield) / prev.yield, else: 0.0)
    )
  end

  defp prev_stream(prev, key), do: Enum.find(prev.streams, &(&1.key == key))

  @mix_classes ["bg-navy", "bg-navy-soft", "bg-steel", "bg-positive"]
  defp mix_class(i), do: Enum.at(@mix_classes, rem(i, length(@mix_classes)))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} identity={@identity} current_path={@current_path}>
      <div class="flex flex-col gap-4">
        <div class="flex flex-wrap items-center gap-3">
          <.link
            navigate={~p"/"}
            class="inline-flex items-center gap-1 text-xs font-bold uppercase tracking-wide hover:opacity-70"
          >
            <.icon name="arrow-left" class="size-3" /> {gettext("Dashboard")}
          </.link>
          <h1 class="display-title text-base">{gettext("Revenue & Yield")}</h1>
          <.month_club_filters
            month={@month}
            club_id={@club_id}
            months={Bridge.picker_months()}
            clubs={Bridge.clubs()}
            current_month={@current_month}
          />
          <span class="ms-auto text-[11px] text-muted">
            Revenue = transactions × unit AED · read-only
          </span>
        </div>

        <div class="grid gap-3 sm:grid-cols-2">
          <div
            :for={
              {label, value, delta, line} <- [
                {gettext("MTD revenue collected"), aed_short(@view.net),
                 "#{signed_pct(@rev_delta)} vs last month same day",
                 "gross #{aed_short(@view.gross)} · refunds #{aed_short(@view.refunds)} · of #{aed_short(@view.revenue_target)} target (#{pct(if @view.revenue_target > 0, do: @view.net / @view.revenue_target, else: 0)})"},
                {gettext("MTD yield"), "#{aed(@view.yield)} / txn",
                 "#{signed_pct(@yield_delta)} vs last month same day",
                 "#{num(@view.totals.collected_transactions)} collecting transactions · last month #{aed(@prev.yield)}"}
              ]
            }
            class="flex flex-col rounded-xl bg-base-100 px-4 py-3 ring-1 ring-base-300"
          >
            <p class="text-[11px] font-extrabold uppercase tracking-[0.12em] text-muted">{label}</p>
            <p class="display-title mt-1.5 text-[32px] leading-none tabular-nums">{value}</p>
            <p class="mt-2 text-[10px] text-muted">{delta}</p>
            <p class="mt-1 text-[11px] text-muted">{line}</p>
          </div>
        </div>

        <div class="rounded-xl bg-base-100 p-4 ring-1 ring-base-300">
          <p class="text-[11px] font-extrabold uppercase tracking-[0.12em] text-muted">
            {gettext("Revenue mix")}
          </p>
          <div class="mt-3 flex h-4 w-full overflow-hidden rounded-full bg-base-200">
            <div
              :for={{s, i} <- Enum.with_index(Enum.filter(@view.streams, &(&1.sign == 1)))}
              title={"#{s.label} #{pct(s.share)}"}
              class={["h-full", mix_class(i)]}
              style={"width: #{s.share * 100}%"}
            >
            </div>
          </div>
          <div class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-muted">
            <span
              :for={{s, i} <- Enum.with_index(Enum.filter(@view.streams, &(&1.sign == 1)))}
              class="inline-flex items-center gap-1.5"
            >
              <span class={["size-2 rounded-sm", mix_class(i)]}></span> {s.label} {pct(s.share)}
            </span>
          </div>
        </div>

        <div class="overflow-x-auto rounded-xl bg-base-100 ring-1 ring-base-300">
          <table class="w-full min-w-[720px] text-sm">
            <caption class="px-4 pt-3 text-start text-[11px] font-extrabold uppercase tracking-[0.12em] text-muted">
              Revenue &amp; yield by stream — {if @month == @current_month, do: "MTD", else: "full month"}
            </caption>
            <thead>
              <tr class="border-b border-base-300 text-[11px] uppercase tracking-wide text-muted">
                <th class="px-4 py-2 text-start font-bold">Stream</th>
                <th class="px-3 py-2 text-end font-bold">Txns</th>
                <th class="px-3 py-2 text-end font-bold">Revenue</th>
                <th class="px-3 py-2 text-end font-bold">Yield / txn</th>
                <th class="px-3 py-2 text-end font-bold">Mix</th>
                <th class="px-4 py-2 text-end font-bold">vs last month</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={s <- @view.streams} class="border-b border-base-300/60 last:border-0">
                <td class="px-4 py-2.5">
                  <p class="font-bold">{s.label}</p>
                  <p class="text-[11px] text-muted">{s.note}</p>
                </td>
                <td class="px-3 py-2.5 text-end tabular-nums">{num(s.txns)}</td>
                <td class={["px-3 py-2.5 text-end font-bold tabular-nums", s.sign == -1 && "text-negative"]}>
                  {aed(s.revenue)}
                </td>
                <td class="px-3 py-2.5 text-end tabular-nums">{aed(abs(s.yield))}</td>
                <td class="px-3 py-2.5 text-end tabular-nums">{if s.sign == 1, do: pct(s.share), else: "—"}</td>
                <td class={[
                  "px-4 py-2.5 text-end tabular-nums",
                  stream_delta(@prev, s) < 0 && s.sign == 1 && "text-negative"
                ]}>
                  {if prev_stream(@prev, s.key), do: signed_pct(stream_delta(@prev, s)), else: "—"}
                </td>
              </tr>
              <tr class="bg-base-200/40 font-extrabold">
                <td class="px-4 py-2.5">Net revenue</td>
                <td class="px-3 py-2.5 text-end tabular-nums">{num(@view.totals.collected_transactions)}</td>
                <td class="whitespace-nowrap px-3 py-2.5 text-end tabular-nums">{aed(@view.net)}</td>
                <td class="px-3 py-2.5 text-end tabular-nums">{aed(@view.yield)}</td>
                <td class="px-3 py-2.5 text-end">100%</td>
                <td class="px-4 py-2.5 text-end tabular-nums">{signed_pct(@rev_delta)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="overflow-x-auto rounded-xl bg-base-100 ring-1 ring-base-300">
          <table class="w-full min-w-[560px] text-sm">
            <caption class="px-4 pt-3 text-start text-[11px] font-extrabold uppercase tracking-[0.12em] text-muted">
              Revenue &amp; yield by club
            </caption>
            <thead>
              <tr class="border-b border-base-300 text-[11px] uppercase tracking-wide text-muted">
                <th class="px-4 py-2 text-start font-bold">Club</th>
                <th class="px-3 py-2 text-end font-bold">Txns</th>
                <th class="px-3 py-2 text-end font-bold">Revenue</th>
                <th class="px-3 py-2 text-end font-bold">Yield / txn</th>
                <th class="px-4 py-2 text-end font-bold">Upfront mix</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={c <- @by_club}
                phx-click="select-club"
                phx-value-club={c.club_id}
                class={[
                  "cursor-pointer border-b border-base-300/60 last:border-0 hover:bg-base-200/40",
                  @club_id == c.club_id && "bg-navy-soft"
                ]}
              >
                <td class="px-4 py-2.5 font-bold">{c.name}</td>
                <td class="px-3 py-2.5 text-end tabular-nums">{num(c.txns)}</td>
                <td class="px-3 py-2.5 text-end font-bold tabular-nums">{aed(c.revenue)}</td>
                <td class="px-3 py-2.5 text-end tabular-nums">{aed(c.yield)}</td>
                <td class="px-4 py-2.5 text-end tabular-nums">{pct(c.upfront_mix)}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <p class="text-[11px] leading-[16px] text-muted">
          Unit prices (placeholder): recurring AED 219 · new sale AED 229 · upfront AED 209 · recovery AED 199
          · refund AED 229. Every membership payment is one transaction of a similar value — a 12-month
          contract paid upfront counts as 1 new sale + 11 upfront transactions, so upfronts add volume, not
          big-ticket revenue. Yield = net revenue ÷ collecting transactions.
        </p>
      </div>
    </Layouts.app>
    """
  end

  defp stream_delta(prev, s) do
    case prev_stream(prev, s.key) do
      nil -> 0.0
      p when p.revenue == 0 -> 0.0
      p -> (s.revenue - p.revenue) / abs(p.revenue)
    end
  end
end
