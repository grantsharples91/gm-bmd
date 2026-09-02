defmodule GmBmd.Targets do
  @moduledoc """
  GM TARGETS — the persisted T2 target set per club per month, and how the
  dashboard resolves what to compare against: approved T2 → draft → last
  month's actuals. The business runs a lower T1 and a full T2; only T2 is
  captured here. KPIs are stored as strings, exposed as atoms.
  """

  import Ecto.Query

  alias GmBmd.Bridge
  alias GmBmd.Gm
  alias GmBmd.Repo
  alias GmBmd.Targets.{GmForecast, Target, TargetState}

  @target_kpis [
    %{key: :total, label: "MTD Transactions", hint: "month-end total transactions target"},
    %{key: :new_sales, label: "New Sales", hint: "T2 new membership sales"},
    %{
      key: :defaults,
      label: "O/S Defaults",
      hint: "ceiling — the most OUTSTANDING (uncollected) defaults planned at month end"
    },
    %{key: :prior_recoveries, label: "Prior Recoveries", hint: "T2 default collections from prior months"},
    %{key: :upfront, label: "Upfronts", hint: "T2 upfront / paid-in-full transactions"}
  ]

  @kpi_keys Enum.map(@target_kpis, & &1.key)

  def target_kpis, do: @target_kpis
  def kpi_keys, do: @kpi_keys

  @doc "Full-month actual for one KPI (the bridge is the source of truth)."
  def actual_for(month, club_id, kpi) do
    club_id
    |> Gm.club_ids()
    |> Enum.map(fn id ->
      case Bridge.bridge_for(id, month) do
        nil ->
          0

        b ->
          case kpi do
            :total -> b.total
            :defaults -> max(b.defaults_raised - b.defaults_recovered, 0)
            :prior_recoveries -> b.flows.prior_default_collections
            :new_sales -> b.flows.new_sales
            :upfront -> b.flows.upfront
          end
      end
    end)
    |> Enum.sum()
  end

  def prev_month_key(month) do
    months = Bridge.months()
    idx = Enum.find_index(months, &(&1.key == month))
    if idx && idx > 0, do: Enum.at(months, idx - 1).key, else: month
  end

  # ---------------------------------------------------------------- storage

  @doc "All target values for a month as %{{club_id, kpi} => value}."
  def values_for_month(month) do
    ensure_seeded()

    from(t in Target, where: t.month == ^month)
    |> Repo.all()
    |> Map.new(fn t -> {{t.club_id, String.to_existing_atom(t.kpi)}, t.t2_value} end)
  end

  def value_for(month, club_id, kpi) do
    ensure_seeded()

    from(t in Target, where: t.month == ^month and t.club_id == ^club_id and t.kpi == ^to_string(kpi))
    |> Repo.one()
    |> case do
      nil -> nil
      t -> t.t2_value
    end
  end

  def set_value(month, club_id, kpi, value) do
    ensure_seeded()
    value = value |> round() |> max(0)

    Repo.insert!(
      Target.changeset(%Target{}, %{month: month, club_id: club_id, kpi: to_string(kpi), t2_value: value}),
      on_conflict: [set: [t2_value: value, updated_at: DateTime.utc_now()]],
      conflict_target: [:month, :club_id, :kpi]
    )

    mark_draft(month, club_id)
    :ok
  end

  @doc "Fill one club's grid from last month's full-month actuals."
  def use_last_month_actuals(month, club_id) do
    prev = prev_month_key(month)
    Enum.each(@kpi_keys, fn kpi -> set_value(month, club_id, kpi, actual_for(prev, club_id, kpi)) end)
  end

  @doc "Copy last month's T2 targets into this month for one club."
  def copy_last_month_targets(month, club_id) do
    prev = prev_month_key(month)

    Enum.each(@kpi_keys, fn kpi ->
      set_value(month, club_id, kpi, value_for(prev, club_id, kpi) || actual_for(prev, club_id, kpi))
    end)
  end

  def approve(month, club_id, by) do
    upsert_state(month, club_id, %{
      status: "approved",
      approved_by: by,
      approved_at: DateTime.utc_now(),
      unlock_reason: nil,
      unlocked_by: nil
    })
  end

  def unlock(month, club_id, reason, by) do
    upsert_state(month, club_id, %{status: "draft", unlock_reason: reason, unlocked_by: by})
  end

  defp mark_draft(month, club_id) do
    if club_state(month, club_id) == nil do
      upsert_state(month, club_id, %{status: "draft"})
    end

    :ok
  end

  defp upsert_state(month, club_id, attrs) do
    now = DateTime.utc_now()

    sets =
      attrs
      |> Map.put(:updated_at, now)
      |> Enum.to_list()

    Repo.insert!(
      TargetState.changeset(%TargetState{}, Map.merge(%{month: month, club_id: club_id}, attrs)),
      on_conflict: [set: sets],
      conflict_target: [:month, :club_id]
    )

    :ok
  end

  @doc "Approval state for one club's month, or nil when none exists yet."
  def club_state(month, club_id) do
    ensure_seeded()

    from(s in TargetState, where: s.month == ^month and s.club_id == ^club_id)
    |> Repo.one()
  end

  @doc "State for a selection: one club's row, or the rolled-up month state for \"all\"."
  def month_state(month, club_id) do
    if Gm.single?(club_id) do
      club_state(month, club_id)
    else
      states = Enum.map(Gm.club_ids(club_id), &club_state(month, &1))
      rollup(states)
    end
  end

  defp rollup(states) do
    present = Enum.reject(states, &is_nil/1)

    cond do
      present == [] ->
        nil

      length(present) != length(states) or Enum.any?(present, &(&1.status != "approved")) ->
        reopened = Enum.find(present, & &1.unlock_reason)

        %TargetState{
          status: "draft",
          unlock_reason: reopened && reopened.unlock_reason,
          unlocked_by: reopened && reopened.unlocked_by
        }

      true ->
        Enum.max_by(present, &(&1.approved_at || ~U[1970-01-01 00:00:00.000000Z]), DateTime)
    end
  end

  # -------------------------------------------------------------- resolution

  @doc """
  Resolved comparator for the dashboard: approved T2 → draft → last month's
  actuals. Returns `%{values, source, note, month_state}` with `source` one of
  `:approved | :draft | :fallback`.
  """
  def resolve(month, club_id, month_label \\ nil) do
    month_label = month_label || month
    state = month_state(month, club_id)
    values = values_for_month(month)
    ids = Gm.club_ids(club_id)

    has_rows? =
      Enum.any?(values, fn {{cid, _kpi}, _v} -> cid in ids end)

    if not has_rows? or state == nil do
      prev = prev_month_key(month)

      %{
        values: Map.new(@kpi_keys, fn kpi -> {kpi, actual_for(prev, club_id, kpi)} end),
        source: :fallback,
        note: "No targets set for #{month_label} — comparing against last month's actuals.",
        month_state: state
      }
    else
      summed =
        Map.new(@kpi_keys, fn kpi ->
          {kpi, ids |> Enum.map(fn id -> Map.get(values, {id, kpi}, 0) end) |> Enum.sum()}
        end)

      source = if state.status == "approved", do: :approved, else: :draft

      note =
        if source == :approved do
          stamp = if state.approved_at, do: " · #{stamp_label(state.approved_at)}", else: ""
          "T2 targets approved by #{state.approved_by || "manager"}#{stamp}"
        else
          "#{month_label} targets not approved yet — comparing against draft."
        end

      %{values: summed, source: source, note: note, month_state: state}
    end
  end

  @month_short ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @doc "Deterministic UTC stamp — \"1 Sep 09:12\"."
  def stamp_label(%DateTime{} = dt) do
    hh = dt.hour |> to_string() |> String.pad_leading(2, "0")
    mm = dt.minute |> to_string() |> String.pad_leading(2, "0")
    "#{dt.day} #{Enum.at(@month_short, dt.month - 1)} #{hh}:#{mm}"
  end

  # ------------------------------------------------------------ GM forecasts

  def gm_forecast(month, club_id) do
    from(f in GmForecast, where: f.month == ^month and f.club_id == ^club_id)
    |> Repo.one()
    |> case do
      nil -> nil
      f -> f.value
    end
  end

  def save_gm_forecast(month, club_id, value, saved_by) do
    value = round(value)

    Repo.insert!(
      GmForecast.changeset(%GmForecast{}, %{month: month, club_id: club_id, value: value, saved_by: saved_by}),
      on_conflict: [set: [value: value, saved_by: saved_by, updated_at: DateTime.utc_now()]],
      conflict_target: [:month, :club_id]
    )

    :ok
  end

  def clear_gm_forecast(month, club_id) do
    from(f in GmForecast, where: f.month == ^month and f.club_id == ^club_id)
    |> Repo.delete_all()

    :ok
  end

  # ----------------------------------------------------------------- seeding

  @seed_factor %{total: 1.005, new_sales: 0.99, defaults: 1.08, prior_recoveries: 1.03, upfront: 1.0}

  @doc """
  First-boot seeding: previous + current month approved, next month draft —
  values from the bridge plan × a small factor, rounded to 5s. Idempotent.
  """
  def ensure_seeded do
    if Repo.aggregate(Target, :count) == 0 do
      current = Bridge.current_month_key()
      months = Bridge.months() |> Enum.map(& &1.key)
      idx = Enum.find_index(months, &(&1 == current)) || 0

      seed_months =
        [Enum.at(months, max(idx - 1, 0)), current, Enum.at(months, idx + 1)]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      now = DateTime.utc_now()

      for month <- seed_months, club <- Bridge.clubs() do
        for kpi <- @kpi_keys do
          value =
            round(actual_for(month, club.id, kpi) * Map.fetch!(@seed_factor, kpi) / 5) * 5

          Repo.insert!(
            Target.changeset(%Target{}, %{
              month: month,
              club_id: club.id,
              kpi: to_string(kpi),
              t2_value: max(value, 0)
            }),
            on_conflict: :nothing,
            conflict_target: [:month, :club_id, :kpi]
          )
        end

        status = if month <= current, do: "approved", else: "draft"

        attrs =
          if status == "approved",
            do: %{status: "approved", approved_by: "Grant", approved_at: now},
            else: %{status: "draft"}

        Repo.insert!(
          TargetState.changeset(
            %TargetState{},
            Map.merge(%{month: month, club_id: club.id}, attrs)
          ),
          on_conflict: :nothing,
          conflict_target: [:month, :club_id]
        )
      end

      :ok
    else
      :ok
    end
  end
end
