defmodule GmBmd.Bridge.Ingest do
  @moduledoc """
  Writes a THOR feed payload into the `bridge_*` tables.

  This is the contract between the dashboard and the platform: whatever
  syncs the feed (a THOR job calling `POST /api/ingest`, or the boot-time
  loader reading `priv/bridge/thor_snapshot.json`) sends this JSON shape:

      {
        "as_of": "2026-08-30",                 // last date with data
        "source": "THOR Executive Forecast …", // free text, shown in the UI
        "generated_at": "2026-08-31T07:34:41Z",
        "clubs": [{"id": "club-al-ain", "name": "Al Ain", "city": ""}],
        "month_bridges": [{"club_id", "month": "YYYY-MM", "opening", "flows": {…9 keys…},
                           "defaults_raised", "defaults_recovered", "total", "net_growth",
                           "revenue_aed", "recurring_collected",
                           "transactions"}],            // THOR Transaction_Count = closing total
        "day_rows":      [{"club_id", "date": "YYYY-MM-DD", "flows": {…}, "defaults_raised",
                           "defaults_recovered", "recurring_collected", "revenue_aed",
                           "transactions"}],            // movement in the count that day
        "billing_runs":  [{"club_id", "date", "members_due", "last_collected_pct"}]
      }

  Every list is optional; rows upsert on (club_id, month) / (club_id, date),
  so a daily sync can send only the current month. Clubs not in the payload
  are kept; set `"replace": true` to wipe the tables first (full reload).
  """

  import Ecto.Query

  alias GmBmd.Bridge
  alias GmBmd.Bridge.DB
  alias GmBmd.Repo

  @chunk 500

  @doc "Load a payload (decoded JSON map). Returns `{:ok, counts}` or raises."
  def load!(payload) when is_map(payload) do
    counts =
      Repo.transaction(fn ->
        if payload["replace"] == true, do: wipe()

        clubs = Enum.map(payload["clubs"] || [], &club_row/1)
        months = Enum.map(payload["month_bridges"] || [], &month_row/1)
        days = Enum.map(payload["day_rows"] || [], &day_row/1)
        runs = Enum.map(payload["billing_runs"] || [], &run_row/1)

        upsert("bridge_clubs", clubs, [:id])
        upsert("bridge_months", months, [:club_id, :month])
        upsert("bridge_days", days, [:club_id, :date])
        upsert("billing_runs", runs, [:club_id, :date])

        meta =
          [
            {"as_of", payload["as_of"]},
            {"source", payload["source"]},
            {"generated_at", payload["generated_at"]},
            {"ingested_at", DateTime.utc_now() |> DateTime.to_iso8601()}
          ]
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.map(fn {k, v} -> %{key: k, value: to_string(v)} end)

        upsert("bridge_meta", meta, [:key])

        %{
          clubs: length(clubs),
          month_bridges: length(months),
          day_rows: length(days),
          billing_runs: length(runs)
        }
      end)

    DB.reload()
    counts
  end

  @doc "Load the JSON file shipped in priv (the bootstrap snapshot)."
  def load_file!(path) do
    path |> File.read!() |> Jason.decode!() |> load!()
  end

  @doc "Row counts per table — for the status endpoint."
  def counts do
    %{
      clubs: count("bridge_clubs"),
      month_bridges: count("bridge_months"),
      day_rows: count("bridge_days"),
      billing_runs: count("billing_runs")
    }
  end

  defp count(table), do: from(t in table) |> Repo.aggregate(:count)

  @doc "The bridge_meta rows as a map (as_of, source, generated_at, ingested_at)."
  def meta do
    from(m in "bridge_meta", select: {m.key, m.value}) |> Repo.all() |> Map.new()
  end

  defp wipe do
    for table <- ~w(bridge_clubs bridge_months bridge_days billing_runs bridge_meta) do
      Repo.delete_all(from(t in table))
    end
  end

  defp upsert(_table, [], _conflict), do: :ok

  defp upsert(table, rows, conflict) do
    replace = rows |> hd() |> Map.keys() |> Kernel.--(conflict)

    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.each(fn chunk ->
      Repo.insert_all(table, chunk,
        on_conflict: {:replace, replace},
        conflict_target: conflict
      )
    end)
  end

  # ------------------------------------------------------------------- rows

  defp club_row(c) do
    %{
      id: c["id"],
      name: c["name"] || c["id"],
      city: c["city"] || "",
      sort: int(c["sort"])
    }
  end

  defp month_row(m) do
    %{
      club_id: m["club_id"],
      month: m["month"],
      kind: m["kind"] || "actual",
      opening: int(m["opening"]),
      flows: flows(m["flows"]),
      defaults_raised: int(m["defaults_raised"]),
      defaults_recovered: int(m["defaults_recovered"]),
      total: int(m["total"]),
      net_growth: int(m["net_growth"]),
      revenue_aed: (m["revenue_aed"] || 0) * 1.0,
      recurring_collected: int(m["recurring_collected"]),
      transactions: opt_int(m["transactions"])
    }
  end

  defp day_row(d) do
    %{
      club_id: d["club_id"],
      date: Date.from_iso8601!(d["date"]),
      flows: flows(d["flows"]),
      defaults_raised: int(d["defaults_raised"]),
      defaults_recovered: int(d["defaults_recovered"]),
      recurring_collected: int(d["recurring_collected"]),
      revenue_aed: int(d["revenue_aed"]),
      transactions: opt_int(d["transactions"])
    }
  end

  defp run_row(r) do
    %{
      club_id: r["club_id"],
      date: Date.from_iso8601!(r["date"]),
      members_due: int(r["members_due"]),
      last_collected_pct: (r["last_collected_pct"] || 0) * 1.0
    }
  end

  defp flows(map) do
    map = map || %{}
    Map.new(Bridge.bridge_row_keys(), fn key -> {to_string(key), int(map[to_string(key)])} end)
  end

  defp opt_int(nil), do: nil
  defp opt_int(v), do: int(v)

  defp int(nil), do: 0
  defp int(v) when is_integer(v), do: v
  defp int(v) when is_float(v), do: round(v)
  defp int(v) when is_binary(v), do: v |> String.to_integer()
end
