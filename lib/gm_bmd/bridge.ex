defmodule GmBmd.Bridge do
  @moduledoc """
  The data boundary for everything the dashboard reads.

  All screen maths goes through this module, which delegates to the configured
  `GmBmd.Bridge.Source`. In dev and prod that is `GmBmd.Bridge.DB` — the THOR
  feed in the `bridge_*` tables, filled by `POST /api/ingest` or the boot-time
  snapshot loader; tests run on `GmBmd.Bridge.Seeds` (deterministic
  placeholder data, same shape). `config :gm_bmd, :bridge_source` picks.
  """

  @bridge_rows [
    %{key: :duplicates, label: "Duplicates from prior month", short: "Duplicates", sign: -1},
    %{key: :new_sales, label: "New membership sales", short: "New sales", sign: 1},
    %{
      key: :prior_default_collections,
      label: "Default collections from prior months",
      short: "Prior collections",
      sign: 1
    },
    %{key: :upfront, label: "Upfront membership transactions", short: "Upfront", sign: 1},
    %{
      key: :agency_collections,
      label: "Default collections from third-party debt agency",
      short: "Agency",
      sign: 1
    },
    %{
      key: :cancel_within,
      label: "Cancellations (actioned within month)",
      short: "Cancels within",
      sign: -1
    },
    %{
      key: :cancel_prior,
      label: "Cancellations (actioned prior month)",
      short: "Cancels prior",
      sign: -1
    },
    %{
      key: :defaults,
      label: "Defaults of people who paid in prior month",
      short: "Defaults",
      sign: -1
    },
    %{key: :refunds, label: "Refunds", short: "Refunds", sign: -1}
  ]

  @bridge_row_keys Enum.map(@bridge_rows, & &1.key)

  # Fixed rows — known on day 1, no accrual, no projection.
  @fixed_rows [:duplicates, :cancel_prior]

  @unit_aed %{recurring: 219, new_sale: 229, upfront: 209, recovery: 199, refund: 229}

  def bridge_rows, do: @bridge_rows
  def bridge_row_keys, do: @bridge_row_keys
  def fixed_rows, do: @fixed_rows
  def fixed_row?(key), do: key in @fixed_rows
  def unit_aed, do: @unit_aed

  def zero_flows, do: Map.new(@bridge_row_keys, &{&1, 0})

  defp source, do: Application.get_env(:gm_bmd, :bridge_source, GmBmd.Bridge.Seeds)

  def clubs, do: source().clubs()
  def months, do: source().months()
  def month_bridges, do: source().month_bridges()
  def day_rows(month), do: source().day_rows(month)
  def billing_runs(month), do: source().billing_runs(month)
  def finance_targets, do: source().finance_targets()
  def as_of, do: source().as_of()

  def club_name(club_id) do
    case Enum.find(clubs(), &(&1.id == club_id)) do
      nil -> "—"
      club -> club.name
    end
  end

  def month_meta(month), do: Enum.find(months(), &(&1.key == month))

  def bridge_for(club_id, month),
    do: Enum.find(month_bridges(), &(&1.club_id == club_id and &1.month == month))

  @doc """
  Current month key ('YYYY-MM') — today's month, never past the feed's as-of
  month (the dashboard stays on the last month with data until the next
  sync), clamped into the dataset.
  """
  def current_month_key do
    keys = Enum.map(months(), & &1.key)
    today = today_dubai()
    key = month_key(today.year, today.month)

    key =
      case as_of() do
        %Date{} = as_of -> min(key, month_key(as_of.year, as_of.month))
        nil -> key
      end

    if key in keys, do: key, else: List.last(keys)
  end

  @doc """
  Day of month for MTD maths — today when the current month is live, the full
  month when it has closed, and never past the feed's as-of date so MTD never
  claims days the data does not cover.
  """
  def today_day do
    today = today_dubai()
    current = current_month_key()
    [year, month] = current |> String.split("-") |> Enum.map(&String.to_integer/1)

    day =
      if month_key(today.year, today.month) == current,
        do: today.day,
        else: Date.days_in_month(Date.new!(year, month, 1))

    case as_of() do
      %Date{} = as_of ->
        if month_key(as_of.year, as_of.month) == current, do: min(day, as_of.day), else: day

      nil ->
        day
    end
  end

  @doc "Months selectable on the dashboards: up to the current month, newest first."
  def picker_months do
    current = current_month_key()
    months() |> Enum.filter(&(&1.key <= current)) |> Enum.reverse()
  end

  def month_key(year, month), do: "#{year}-#{String.pad_leading(to_string(month), 2, "0")}"

  def days_in_month(%{year: year, month: month}),
    do: Date.days_in_month(Date.new!(year, month, 1))

  @doc "Today in Dubai (UTC+4) — the business calendar every screen runs on."
  def today_dubai do
    DateTime.utc_now() |> DateTime.add(4 * 3600, :second) |> DateTime.to_date()
  end
end
