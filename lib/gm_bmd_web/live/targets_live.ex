defmodule GmBmdWeb.TargetsLive do
  @moduledoc """
  Monthly T2 targets — set one club at a time (transactions, new sales, O/S
  defaults ceiling, prior recoveries, upfronts), per-club approval with a
  status-by-club strip, history vs actual, and unlock-with-reason.
  """
  use GmBmdWeb, :live_view

  alias GmBmd.{Bridge, Targets}
  alias GmBmdWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Monthly Targets",
       month: default_month(),
       club_id: "",
       confirming: false,
       unlocking: false,
       unlock_reason: "",
       history_open: false
     )
     |> load()}
  end

  defp default_month do
    months = Bridge.months()
    current = Bridge.current_month_key()
    idx = Enum.find_index(months, &(&1.key == current)) || 0
    next = Enum.at(months, idx + 1)
    if Bridge.today_day() >= 25 and next, do: next.key, else: current
  end

  @impl true
  def handle_event("pick", params, socket) do
    month =
      case Map.get(params, "month") do
        nil -> socket.assigns.month
        m -> if Enum.any?(Bridge.months(), &(&1.key == m)), do: m, else: socket.assigns.month
      end

    club_id =
      case Map.get(params, "club_id") do
        nil -> socket.assigns.club_id
        "" -> ""
        c -> if Enum.any?(Bridge.clubs(), &(&1.id == c)), do: c, else: socket.assigns.club_id
      end

    {:noreply, socket |> assign(month: month, club_id: club_id, history_open: false) |> load()}
  end

  def handle_event("pick-club", %{"club" => club_id}, socket) do
    club_id = if Enum.any?(Bridge.clubs(), &(&1.id == club_id)), do: club_id, else: ""
    {:noreply, socket |> assign(club_id: club_id) |> load()}
  end

  def handle_event("set-value", %{"kpi" => kpi, "value" => value} = _params, socket) do
    %{month: month, club_id: club_id, locked: locked} = socket.assigns
    kpi_atom = Enum.find(Targets.kpi_keys(), &(to_string(&1) == kpi))

    if club_id != "" and not locked and kpi_atom do
      case Integer.parse(to_string(value)) do
        {n, _} -> Targets.set_value(month, club_id, kpi_atom, n)
        :error -> :ok
      end
    end

    {:noreply, load(socket)}
  end

  def handle_event("use-last-actuals", _params, socket) do
    %{month: month, club_id: club_id, locked: locked} = socket.assigns
    if club_id != "" and not locked, do: Targets.use_last_month_actuals(month, club_id)
    {:noreply, load(socket)}
  end

  def handle_event("copy-last-targets", _params, socket) do
    %{month: month, club_id: club_id, locked: locked} = socket.assigns
    if club_id != "" and not locked, do: Targets.copy_last_month_targets(month, club_id)
    {:noreply, load(socket)}
  end

  def handle_event("confirm-approve", _params, socket),
    do: {:noreply, assign(socket, confirming: true)}

  def handle_event("cancel-dialog", _params, socket),
    do: {:noreply, assign(socket, confirming: false, unlocking: false, unlock_reason: "")}

  def handle_event("approve", _params, socket) do
    %{month: month, club_id: club_id, identity: identity} = socket.assigns

    if club_id != "" do
      Targets.approve(month, club_id, GmBmdWeb.Identity.display_name(identity))
    end

    {:noreply, socket |> assign(confirming: false) |> load()}
  end

  def handle_event("start-unlock", _params, socket),
    do: {:noreply, assign(socket, unlocking: true, unlock_reason: "")}

  def handle_event("unlock-reason", %{"reason" => reason}, socket),
    do: {:noreply, assign(socket, unlock_reason: reason)}

  def handle_event("unlock", _params, socket) do
    %{month: month, club_id: club_id, unlock_reason: reason, identity: identity} = socket.assigns

    if club_id != "" and String.length(String.trim(reason)) >= 3 do
      Targets.unlock(month, club_id, String.trim(reason), GmBmdWeb.Identity.display_name(identity))
    end

    {:noreply, socket |> assign(unlocking: false, unlock_reason: "") |> load()}
  end

  def handle_event("toggle-history", _params, socket),
    do: {:noreply, assign(socket, history_open: not socket.assigns.history_open)}

  defp load(socket) do
    %{month: month, club_id: club_id} = socket.assigns
    meta = Bridge.month_meta(month) || hd(Bridge.months())
    prev = Targets.prev_month_key(month)
    prev_meta = Bridge.month_meta(prev)
    state = if club_id != "", do: Targets.club_state(month, club_id)
    locked = state != nil and state.status == "approved"

    club_states =
      Map.new(Bridge.clubs(), fn c ->
        {c.id, Targets.club_state(month, c.id)}
      end)

    values =
      if club_id != "" do
        Map.new(Targets.kpi_keys(), fn kpi -> {kpi, Targets.value_for(month, club_id, kpi) || 0} end)
      else
        %{}
      end

    prev_values =
      if club_id != "" do
        Map.new(Targets.kpi_keys(), fn kpi ->
          {kpi,
           %{
             actual: Targets.actual_for(prev, club_id, kpi),
             target: Targets.value_for(prev, club_id, kpi)
           }}
        end)
      else
        %{}
      end

    totals =
      Map.new(Targets.kpi_keys(), fn kpi ->
        {kpi,
         Bridge.clubs() |> Enum.map(fn c -> Targets.value_for(month, c.id, kpi) || 0 end) |> Enum.sum()}
      end)

    history =
      if club_id != "" do
        months = Bridge.months()
        idx = Enum.find_index(months, &(&1.key == month)) || 0

        months
        |> Enum.slice(max(idx - 6, 0), min(idx, 6))
        |> Enum.reverse()
        |> Enum.map(fn m ->
          %{
            meta: m,
            state: Targets.club_state(m.key, club_id),
            rows:
              Enum.map(Targets.target_kpis(), fn k ->
                %{
                  kpi: k,
                  target: Targets.value_for(m.key, club_id, k.key) || 0,
                  actual: Targets.actual_for(m.key, club_id, k.key)
                }
              end)
          }
        end)
      else
        []
      end

    assign(socket,
      meta: meta,
      prev_month: prev,
      prev_label: (prev_meta && prev_meta.label) || prev,
      state: state,
      locked: locked,
      club_states: club_states,
      values: values,
      prev_values: prev_values,
      totals: totals,
      history: history,
      selected: Enum.find(Bridge.clubs(), &(&1.id == club_id))
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
          <h1 class="display-title text-sm">{gettext("Monthly targets · T2")}</h1>
          <form phx-change="pick" class="contents">
            <select name="month" class="select-field" aria-label="Target month">
              <option :for={m <- Bridge.months()} value={m.key} selected={m.key == @month}>{m.label}</option>
            </select>
            <select name="club_id" class="select-field" aria-label="Club">
              <option value="" selected={@club_id == ""}>Select a club…</option>
              <option :for={c <- Bridge.clubs()} value={c.id} selected={@club_id == c.id}>{c.name}</option>
            </select>
          </form>

          <span
            :if={@selected}
            class={[
              "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[10px] font-extrabold uppercase tracking-wide",
              @locked && "bg-positive-soft text-positive",
              !@locked && "bg-base-200 text-base-content"
            ]}
          >
            <.icon :if={@locked} name="lock" class="size-2.5" />
            {@selected.name} · {if @locked, do: "Approved", else: "Draft"}
          </span>
          <span :if={@locked && @state.approved_at} class="text-[11px] opacity-70">
            by {@state.approved_by} · {Targets.stamp_label(@state.approved_at)}
          </span>
          <span :if={@state && @state.unlock_reason} class="text-[11px] opacity-70">
            Reopened · {@state.unlock_reason}
          </span>

          <div :if={@selected} class="ms-auto flex flex-wrap items-center gap-2">
            <button
              :if={@locked}
              phx-click="start-unlock"
              class="inline-flex items-center gap-1 rounded-md bg-base-200 px-2 py-1.5 text-[11px] font-bold uppercase tracking-wide text-base-content hover:bg-base-300"
            >
              <.icon name="unlock" class="size-3" /> Unlock {@selected.name}
            </button>
            <button
              :if={!@locked}
              phx-click="use-last-actuals"
              class="rounded-md bg-base-200 px-2 py-1.5 text-[11px] font-bold uppercase tracking-wide text-base-content hover:bg-base-300"
            >
              Use last month actual
            </button>
            <button
              :if={!@locked}
              phx-click="copy-last-targets"
              class="rounded-md bg-base-200 px-2 py-1.5 text-[11px] font-bold uppercase tracking-wide text-base-content hover:bg-base-300"
            >
              Copy last month's targets
            </button>
            <button
              :if={!@locked}
              phx-click="confirm-approve"
              class="rounded-md bg-primary px-3 py-1.5 text-[11px] font-extrabold uppercase tracking-wide text-primary-content"
            >
              Approve {@selected.name}
            </button>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-2 rounded-lg bg-base-100 px-3 py-2 ring-1 ring-base-300">
          <span class="text-[10px] font-extrabold uppercase tracking-[0.12em] text-muted">
            Status by club · {@meta.label}
          </span>
          <button
            :for={c <- Bridge.clubs()}
            phx-click="pick-club"
            phx-value-club={c.id}
            class={[
              "inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-[11px] font-bold ring-1 transition",
              approved?(@club_states[c.id]) && "bg-positive-soft text-positive ring-positive/40",
              !approved?(@club_states[c.id]) && "bg-base-200 ring-base-300",
              c.id == @club_id && "ring-2 ring-steel"
            ]}
          >
            <.icon :if={approved?(@club_states[c.id])} name="lock" class="size-2.5" />
            {c.name}
            <span class="font-extrabold uppercase tracking-wide">
              · {if approved?(@club_states[c.id]), do: "Approved", else: "Draft"}
            </span>
          </button>
        </div>

        <div
          :if={!@selected}
          class="grid place-items-center gap-2 rounded-xl bg-base-100 px-4 py-16 text-center ring-1 ring-base-300"
        >
          <.icon name="target" class="size-6 text-muted" />
          <p class="display-title text-base">Select a club to set its targets</p>
          <p class="max-w-md text-xs text-muted">
            Targets are set one club at a time by that site's GM. Pick a club above — or click one of the
            status chips — to enter its five T2 numbers for {@meta.label}.
          </p>
        </div>

        <div :if={@selected} class="contents">
          <p class="text-xs text-muted">
            Enter the <strong class="text-base-content">T2 target</strong>
            — the full target — for <strong class="text-base-content">{@selected.name}</strong>, {@meta.label}.
            The business also runs a lower T1; only T2 is captured here. Once this club is approved, its row
            locks and the GM dashboard reads these numbers for every vs-target comparison, pace line,
            club-table RAG and the outturn target line.
          </p>

          <div class="rounded-xl bg-base-100 p-3 ring-1 ring-base-300">
            <p class="display-title text-sm">{@selected.name}</p>
            <div class="mt-3 grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-5">
              <div :for={k <- Targets.target_kpis()}>
                <p title={k.hint} class="text-[10px] font-extrabold uppercase tracking-wide text-muted">
                  {k.label}
                </p>
                <div class="flex flex-col items-start gap-1">
                  <span :if={@locked} class="inline-flex items-center gap-1 text-base font-extrabold tabular-nums">
                    <.icon name="lock" class="size-3 text-muted" />
                    {num(@values[k.key])}
                  </span>
                  <form :if={!@locked} phx-change="set-value" class="w-full">
                    <input type="hidden" name="kpi" value={k.key} />
                    <input
                      type="number"
                      name="value"
                      min="0"
                      value={@values[k.key]}
                      aria-label={"#{k.label} target"}
                      class="num-field"
                    />
                  </form>
                  <span class="text-[10px] leading-[13px] text-muted">
                    Last month actual {num(@prev_values[k.key].actual)}
                    <br />
                    Last month target {if @prev_values[k.key].target,
                      do: num(@prev_values[k.key].target),
                      else: "—"}
                  </span>
                </div>
              </div>
            </div>

            <div class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 border-t border-base-300 pt-2 text-[11px] text-muted">
              <span class="font-extrabold uppercase tracking-wide">
                All clubs total · computed · read-only
              </span>
              <span :for={k <- Targets.target_kpis()}>
                {k.label} <strong class="tabular-nums text-base-content">{num(@totals[k.key])}</strong>
              </span>
            </div>
          </div>

          <div class="rounded-xl bg-base-100 ring-1 ring-base-300">
            <button
              phx-click="toggle-history"
              class="flex w-full items-center gap-2 px-3 py-2.5 text-start text-[11px] font-extrabold uppercase tracking-[0.12em] text-muted"
            >
              <.icon name="chevron-down" class={["size-3 transition", @history_open && "rotate-180"]} />
              History — {@selected.name}, previous months, T2 vs actual
            </button>
            <div :if={@history_open} class="space-y-4 border-t border-base-300 p-3">
              <p :if={@history == []} class="text-xs text-muted">No earlier months in the dataset.</p>
              <div :for={h <- @history}>
                <p class="text-xs font-bold">
                  {h.meta.label}
                  <span class="font-normal text-muted">
                    {history_state_label(h.state)}
                  </span>
                </p>
                <table class="mt-1 w-full border-collapse text-xs">
                  <thead>
                    <tr class="text-[9px] uppercase tracking-wide text-muted">
                      <th class="px-1 py-1 text-start">KPI</th>
                      <th class="px-1 py-1 text-end">T2</th>
                      <th class="px-1 py-1 text-end">Actual</th>
                      <th class="px-1 py-1 text-end">% achieved</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={r <- h.rows} class="border-t border-base-300">
                      <td class="px-1 py-1">{r.kpi.label}</td>
                      <td class="px-1 py-1 text-end tabular-nums">{if r.target > 0, do: num(r.target), else: "—"}</td>
                      <td class="px-1 py-1 text-end tabular-nums">{num(r.actual)}</td>
                      <td class={[
                        "px-1 py-1 text-end tabular-nums",
                        r.target > 0 && r.actual / r.target < 0.95 && "text-negative"
                      ]}>
                        {if r.target > 0, do: pct0(r.actual / r.target), else: "—"}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div :if={@confirming && @selected} class="fixed inset-0 z-50 grid place-items-center bg-navy/40 p-4">
        <div class="w-full max-w-sm rounded-xl bg-base-100 p-4 ring-1 ring-base-300">
          <p class="display-title text-base">Approve {@selected.name} — {@meta.label}?</p>
          <p class="mt-1 text-sm text-muted">
            This locks this club's row and switches every vs-target comparison on the GM dashboard to these
            numbers.
          </p>
          <div class="mt-4 flex justify-end gap-2">
            <button
              phx-click="cancel-dialog"
              class="rounded-md px-3 py-2 text-xs font-bold uppercase tracking-wide ring-1 ring-base-300"
            >
              Cancel
            </button>
            <button
              phx-click="approve"
              class="rounded-md bg-primary px-3 py-2 text-xs font-extrabold uppercase tracking-wide text-primary-content"
            >
              Approve targets
            </button>
          </div>
        </div>
      </div>

      <div :if={@unlocking && @selected} class="fixed inset-0 z-50 grid place-items-center bg-navy/40 p-4">
        <div class="w-full max-w-sm rounded-xl bg-base-100 p-4 ring-1 ring-base-300">
          <p class="display-title text-base">Reopen {@selected.name} — {@meta.label}?</p>
          <p class="mt-1 text-sm text-muted">Manager action. Give a reason — it is stamped on this club's month.</p>
          <form phx-change="unlock-reason" phx-submit="unlock">
            <input
              name="reason"
              value={@unlock_reason}
              placeholder="Reason for reopening"
              autocomplete="off"
              class="mt-3 w-full rounded-md border border-base-300 px-3 py-2 text-sm outline-none"
            />
          </form>
          <div class="mt-4 flex justify-end gap-2">
            <button
              phx-click="cancel-dialog"
              class="rounded-md px-3 py-2 text-xs font-bold uppercase tracking-wide ring-1 ring-base-300"
            >
              Cancel
            </button>
            <button
              phx-click="unlock"
              disabled={String.length(String.trim(@unlock_reason)) < 3}
              class="rounded-md bg-primary px-3 py-2 text-xs font-extrabold uppercase tracking-wide text-primary-content disabled:opacity-40"
            >
              Unlock
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp approved?(nil), do: false
  defp approved?(state), do: state.status == "approved"

  defp history_state_label(nil), do: "no targets set"

  defp history_state_label(state) do
    if state.status == "approved" do
      stamp = if state.approved_at, do: " · #{Targets.stamp_label(state.approved_at)}", else: ""
      "approved by #{state.approved_by}#{stamp}"
    else
      "draft"
    end
  end
end
