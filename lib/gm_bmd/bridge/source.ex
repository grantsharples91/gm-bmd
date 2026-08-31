defmodule GmBmd.Bridge.Source do
  @moduledoc """
  Behaviour for the dashboard's data feed.

  `GmBmd.Bridge.Seeds` implements it with deterministic placeholder data; the
  production database plug-in implements the same six callbacks over the real
  tables. Shapes:

    * club — `%{id: String.t(), name: String.t(), city: String.t()}`
    * month — `%{key: "YYYY-MM", label: String.t(), year: integer, month: 1..12,
      kind: :actual | :forecast}`
    * month bridge — `%{club_id, month, kind, opening, flows: %{atom => integer},
      defaults_raised, defaults_recovered, total, net_growth}`
    * day row — `%{club_id, date: Date.t(), flows, defaults_raised,
      defaults_recovered, recurring_collected, revenue_aed}`
    * billing run — `%{club_id, month, day, date, members_due,
      last_collected_pct}`
    * finance target — `%{club_id, new_sales_target, upfront_target,
      total_target, revenue_target}`
  """

  @callback clubs() :: [map()]
  @callback months() :: [map()]
  @callback month_bridges() :: [map()]
  @callback day_rows(String.t()) :: [map()]
  @callback billing_runs(String.t()) :: [map()]
  @callback finance_targets() :: [map()]
  @doc "Latest date the feed has data for (nil = data is complete to today)."
  @callback as_of() :: Date.t() | nil
end
