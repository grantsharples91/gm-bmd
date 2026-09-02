defmodule GmBmd.Rules do
  @moduledoc """
  GM DASHBOARD RULES — the "8am GM" layer: what needs attention, what run-rate
  is required from here, and how yesterday compared to a normal day. Pure and
  data-driven; targets come in through a `targets_of` resolver.
  """

  alias GmBmd.Bridge
  alias GmBmd.Format
  alias GmBmd.Gm

  @gm_rules %{
    recovery_floor: 0.6,
    outstanding_ceiling: 0.4,
    behind_pace: 0.07,
    outturn_miss: 0.015,
    cancel_spike: 2,
    ahead_of_pace: 0.1,
    run_rate_hot: 1.25,
    on_pace: 0.97,
    on_pace_outturn: 0.985,
    verdict_miss: 0.01,
    roll_up_clubs: 3,
    visible_attention: 5
  }

  def gm_rules, do: @gm_rules

  @doc "THE one \"need X/day\" calculation — every screen calls this."
  def need_per_day(actual, target, days_left) when days_left > 0,
    do: (target - actual) / days_left

  def need_per_day(_actual, _target, _days_left), do: 0.0

  def run_rate(actual, target, month) do
    %{elapsed: elapsed, total: total} = Gm.expected_by_today(target, month)
    days_left = max(total - elapsed, 0)
    gap = max(target - actual, 0)
    need = max(need_per_day(actual, target, days_left), 0)
    avg = if elapsed > 0, do: actual / elapsed, else: 0.0

    %{
      days_left: days_left,
      gap: gap,
      need_per_day: need,
      avg_per_day: avg,
      hot: need > avg * @gm_rules.run_rate_hot
    }
  end

  # -------------------------------------------------------------- attention

  defp name_of(club_id) do
    Gm.scope_name(club_id)
  end

  defp items_for_selection(month, club_id, targets, outturn_of) do
    all? = club_id == Gm.all_clubs()
    through_day = if month == Bridge.current_month_key(), do: Bridge.today_day()
    t = Gm.aggregate(Gm.rows_for(month, club_id, through_day))
    prev_month = Gm.previous_month_of(month)
    prev = Gm.aggregate(Gm.rows_for(prev_month, club_id, through_day || Bridge.today_day()))
    label = name_of(club_id)
    scope = if all?, do: "", else: "#{label} "

    outstanding_share = if t.defaults_raised > 0, do: t.outstanding / t.defaults_raised, else: 0.0

    outstanding_items =
      if t.defaults_raised > 0 and outstanding_share > @gm_rules.outstanding_ceiling do
        [
          %{
            id: "recovery-#{club_id}",
            tone: :red,
            text:
              "#{Format.num(t.outstanding)} outstanding defaults (#{Format.pct0(outstanding_share)}) at #{if all?, do: "all clubs", else: label} — of #{Format.num(t.defaults_raised)} defaulted · #{Format.num(t.defaults_recovered)} collected (#{Format.pct(t.recovery_pct)})",
            club_id: club_id,
            tab: :club,
            weight: 0,
            cause: "outstanding",
            magnitude: outstanding_share
          }
        ]
      else
        []
      end

    ot = outturn_of.(club_id)

    outturn_items =
      if ot.total_target > 0 and ot.base < ot.total_target * (1 - @gm_rules.outturn_miss) do
        [
          %{
            id: "outturn-#{club_id}",
            tone: :red,
            text:
              "#{scope}month-end outturn #{Format.num(ot.base)} vs #{Format.num(ot.total_target)} target (#{Format.signed(ot.base - ot.total_target)})",
            club_id: club_id,
            tab: :outturn,
            weight: 1,
            cause: "outturn",
            magnitude: (ot.total_target - ot.base) / ot.total_target
          }
        ]
      else
        []
      end

    flow_kpis = [
      %{kpi: :new_sales, label: "new sales", actual: t.flows.new_sales},
      %{kpi: :upfront, label: "upfronts", actual: t.flows.upfront},
      %{kpi: :prior_recoveries, label: "prior recoveries", actual: t.flows.prior_default_collections}
    ]

    pace_items =
      Enum.flat_map(flow_kpis, fn k ->
        target = Map.get(targets, k.kpi, 0)

        if target <= 0 do
          []
        else
          %{expected: expected} = Gm.expected_by_today(target, month)
          gap_pct = if expected > 0, do: (k.actual - expected) / expected, else: 0.0
          rr = run_rate(k.actual, target, month)

          cond do
            gap_pct < -@gm_rules.behind_pace ->
              text =
                if all? do
                  "#{String.capitalize(k.label)} behind pace by #{Format.num(expected - k.actual)} · need #{Format.num(rr.need_per_day)}/day to close (avg #{Format.num(rr.avg_per_day)})"
                else
                  "#{label} #{k.label} #{Format.num(k.actual)}/#{Format.num(target)} · #{round(abs(gap_pct) * 100)}% behind pace"
                end

              [
                %{
                  id: "pace-#{k.kpi}-#{club_id}",
                  tone: :amber,
                  text: text,
                  club_id: club_id,
                  tab: if(all?, do: :outturn, else: :club),
                  weight: 2,
                  cause: "pace-#{k.kpi}",
                  magnitude: abs(gap_pct)
                }
              ]

            gap_pct > @gm_rules.ahead_of_pace ->
              [
                %{
                  id: "ahead-#{k.kpi}-#{club_id}",
                  tone: :grey,
                  text:
                    "#{String.capitalize(k.label)} ahead of forecast#{if all?, do: "", else: " at #{label}"} (+#{round(gap_pct * 100)}%)",
                  club_id: club_id,
                  tab: :club,
                  weight: 9,
                  cause: "ahead-#{k.kpi}",
                  magnitude: gap_pct
                }
              ]

            true ->
              []
          end
        end
      end)

    cancel_items =
      if prev.flows.cancel_within > 0 and
           t.flows.cancel_within > prev.flows.cancel_within * @gm_rules.cancel_spike do
        [
          %{
            id: "cancels-#{club_id}",
            tone: :amber,
            text:
              "#{scope}cancellations within month #{Format.num(t.flows.cancel_within)} vs #{Format.num(prev.flows.cancel_within)} last month same day",
            club_id: club_id,
            tab: :bridge,
            weight: 3,
            cause: "cancels",
            magnitude: t.flows.cancel_within / prev.flows.cancel_within
          }
        ]
      else
        []
      end

    outstanding_items ++ outturn_items ++ pace_items ++ cancel_items
  end

  @cause_label %{
    "outturn" => "Outturn short",
    "outstanding" => "Outstanding defaults high",
    "cancels" => "Cancellations spiking",
    "pace-new_sales" => "New sales behind pace",
    "pace-upfront" => "Upfronts behind pace",
    "pace-prior_recoveries" => "Prior recoveries behind pace",
    "ahead-new_sales" => "New sales ahead of pace",
    "ahead-upfront" => "Upfronts ahead of pace",
    "ahead-prior_recoveries" => "Prior recoveries ahead of pace"
  }

  @doc """
  The NEEDS ATTENTION list — one line per club per issue; when 3+ clubs share a
  cause they roll into one line naming the worst club. Worst first, positive
  exceptions last, one green line when nothing triggers.

  `targets_of` resolves a club id to its KPI target map; `outturn_of` resolves
  a club id to its outturn model (memoise at the call site).
  """
  def attention_items(month, targets_of, outturn_of, scope_club_id) do
    tone_rank = %{red: 0, amber: 1, grey: 2, green: 3}
    sorter = fn xs -> Enum.sort_by(xs, &{tone_rank[&1.tone], &1.weight}) end

    if scope_club_id != Gm.all_clubs() do
      month
      |> items_for_selection(scope_club_id, targets_of.(scope_club_id), outturn_of)
      |> sorter.()
      |> with_green_fallback(scope_club_id)
    else
      all = items_for_selection(month, Gm.all_clubs(), targets_of.(Gm.all_clubs()), outturn_of)

      per_club =
        Enum.flat_map(Bridge.clubs(), fn c ->
          items_for_selection(month, c.id, targets_of.(c.id), outturn_of)
        end)

      by_cause = Enum.group_by(per_club, & &1.cause)

      rolled =
        Enum.flat_map(by_cause, fn {cause, list} ->
          if length(list) >= @gm_rules.roll_up_clubs do
            worst = Enum.max_by(list, & &1.magnitude)

            [
              %{
                worst
                | id: "roll-#{cause}",
                  text:
                    "#{Map.get(@cause_label, cause, cause)} at #{length(list)} clubs — worst #{name_of(worst.club_id)} (−#{:erlang.float_to_binary(abs(worst.magnitude) * 100 / 1, decimals: 1)}%)"
              }
            ]
          else
            list
          end
        end)

      covered = MapSet.new(rolled, & &1.cause)
      out = rolled ++ Enum.reject(all, &MapSet.member?(covered, &1.cause))
      out |> sorter.() |> with_green_fallback(Gm.all_clubs())
    end
  end

  defp with_green_fallback([], scope_club_id) do
    [
      %{
        id: "all-clear",
        tone: :green,
        text:
          "#{name_of(scope_club_id)} on track — outturn within 1.5% of target, every KPI within 7% of pace and recoveries above the 60% floor.",
        club_id: nil,
        tab: nil,
        weight: 0,
        cause: "all-clear",
        magnitude: 0
      }
    ]
  end

  defp with_green_fallback(items, _scope), do: items

  @doc "A club is on pace when new-sales pace ≥ 97% AND outturn ≥ 98.5% of target."
  def clubs_on_pace(month, targets_of, outturn_of) do
    through_day = if month == Bridge.current_month_key(), do: Bridge.today_day()

    on_pace =
      Enum.count(Bridge.clubs(), fn c ->
        kpi = targets_of.(c.id)
        %{expected: expected} = Gm.expected_by_today(Map.get(kpi, :new_sales, 0), month)
        actual = Gm.aggregate(Gm.rows_for(month, c.id, through_day)).flows.new_sales
        pace_ok = expected <= 0 or actual / expected >= @gm_rules.on_pace
        ot = outturn_of.(c.id)
        outturn_ok = ot.total_target <= 0 or ot.base / ot.total_target >= @gm_rules.on_pace_outturn
        pace_ok and outturn_ok
      end)

    %{on_pace: on_pace, total: length(Bridge.clubs())}
  end

  # ------------------------------------------------- yesterday vs a normal day

  defp shape_of(rows, divisor) do
    t = Gm.aggregate(rows)

    %{
      new_sales: t.flows.new_sales / divisor,
      upfront: t.flows.upfront / divisor,
      defaults_raised: t.defaults_raised / divisor,
      defaults_recovered: t.defaults_recovered / divisor,
      cancellations: t.flows.cancel_within / divisor,
      refunds: t.flows.refunds / divisor
    }
  end

  @month_short ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @day_short %{1 => "Mon", 2 => "Tue", 3 => "Wed", 4 => "Thu", 5 => "Fri", 6 => "Sat", 7 => "Sun"}

  def day_label(year, month, day) do
    d = Date.new!(year, month, day)
    "#{@day_short[Date.day_of_week(d)]} #{day} #{Enum.at(@month_short, month - 1)}"
  end

  @doc "Yesterday for the selection, against the trailing 30-day daily average."
  def yesterday_vs_normal(month, club_id) do
    case Bridge.month_meta(month) do
      nil ->
        nil

      meta ->
        dim = Bridge.days_in_month(meta)
        last_day = if month == Bridge.current_month_key(), do: Bridge.today_day(), else: dim
        y_day = last_day - 1

        if y_day < 1 do
          nil
        else
          yesterday =
            Gm.rows_for(month, club_id, y_day)
            |> Enum.filter(&(&1.date.day == y_day))
            |> shape_of(1)

          this_month = Gm.rows_for(month, club_id, y_day)
          need = max(30 - y_day, 0)
          prev_key = Gm.previous_month_of(month)
          prev_meta = Bridge.month_meta(prev_key)

          prev_rows =
            if prev_meta && prev_key != month do
              prev_dim = Bridge.days_in_month(prev_meta)
              Gm.rows_for(prev_key, club_id) |> Enum.filter(&(&1.date.day > prev_dim - need))
            else
              []
            end

          days = min(30, y_day + if(prev_rows != [], do: need, else: 0))
          days = max(days, 1)

          %{
            label: day_label(meta.year, meta.month, y_day),
            yesterday: yesterday,
            normal: shape_of(prev_rows ++ this_month, days)
          }
        end
    end
  end

  @doc "Tomorrow's billing run for the selection — there is a run every calendar day."
  def next_billing_run(month, club_id) do
    case Bridge.month_meta(month) do
      nil ->
        nil

      meta ->
        dim = Bridge.days_in_month(meta)
        from = if month == Bridge.current_month_key(), do: Bridge.today_day(), else: 0
        day = Enum.find(1..dim, &(&1 > from))

        if day == nil do
          nil
        else
          runs =
            Bridge.billing_runs(month)
            |> Enum.filter(fn r ->
              r.day == day and Gm.in_scope?(club_id, r.club_id)
            end)

          if runs == [] do
            nil
          else
            due = runs |> Enum.map(& &1.members_due) |> Enum.sum()

            pct =
              Enum.reduce(runs, 0.0, fn r, acc -> acc + r.last_collected_pct * r.members_due end) /
                max(due, 1)

            %{label: day_label(meta.year, meta.month, day), due: due, last_collected_pct: pct}
          end
        end
    end
  end

  # ------------------------------------------------------------------ verdict

  @doc "One plain-English sentence: are we on track, and what is dragging it."
  def month_verdict(%{month_label: month_label, outturn_base: base, total_target: target, attention: attention}) do
    gap_pct = if target > 0, do: (base - target) / target, else: 0.0

    status =
      cond do
        gap_pct >= -@gm_rules.verdict_miss -> :on
        gap_pct >= -@gm_rules.outturn_miss -> :watch
        true -> :off
      end

    worst =
      Enum.find(attention, &(&1.tone == :red)) || Enum.find(attention, &(&1.tone == :amber))

    pct_text = "#{:erlang.float_to_binary(abs(gap_pct) * 100 / 1, decimals: 1)}%"

    figures =
      if target > 0 do
        " — outturn #{Format.num(base)} vs #{Format.num(target)} (#{if gap_pct > 0, do: "+", else: "−"}#{pct_text})"
      else
        ""
      end

    headline =
      if status == :on,
        do: "#{month_label} is on track#{figures}",
        else: "#{month_label} is tracking #{pct_text} behind target#{figures}"

    drag =
      if status != :on and worst do
        "#{worst.text |> String.split(" · ") |> hd()} is the main drag"
      end

    %{status: status, headline: headline, drag: drag}
  end

  @doc "Plain-English action for a Needs-attention line."
  def attention_action("ahead-" <> _), do: "Good news — nothing to do"
  def attention_action("outturn-" <> _), do: "Open Outturn detail and see which flow is short"
  def attention_action("roll-outturn"), do: "Open Outturn detail and see which flow is short"
  def attention_action("pace-" <> _), do: "Check the daily run-rate needed to close the gap"
  def attention_action("roll-pace" <> _), do: "Check the daily run-rate needed to close the gap"

  def attention_action("recovery-" <> _),
    do: "Push the collections calls — outstanding is the number to shrink"

  def attention_action("roll-outstanding"),
    do: "Push the collections calls — outstanding is the number to shrink"

  def attention_action("cancels-" <> _), do: "Review cancellation reasons in the bridge"
  def attention_action("roll-cancels"), do: "Review cancellation reasons in the bridge"
  def attention_action(_), do: nil
end
