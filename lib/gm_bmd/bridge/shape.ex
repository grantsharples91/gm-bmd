defmodule GmBmd.Bridge.Shape do
  @moduledoc """
  Day-shape helpers shared by the seed generator, the daily forecast and the
  DB source's forward-month synthesis: how a month's total lands across its
  days (UAE trading pattern), and an integer split that sums exactly.
  """

  @doc """
  Relative size of one day's billing run. UAE shape: Fri quiet, Sat heavy, and
  the first days of the month carry the recurring anniversaries.
  """
  def run_shape(day, dow, dim) do
    week =
      case dow do
        :fri -> 0.62
        :sat -> 1.28
        :sun -> 1.06
        _ -> 1.0
      end

    start =
      cond do
        day <= 5 -> 1.45
        day <= 10 -> 1.18
        day > dim - 3 -> 1.08
        true -> 1.0
      end

    week * start
  end

  @doc "Split a total across weights as integers that sum exactly to the total."
  def distribute(total, weights) do
    sum = Enum.sum(weights)

    if sum <= 0 do
      List.duplicate(0, length(weights) - 1) ++ [round(total)]
    else
      raw = Enum.map(weights, fn w -> total * w / sum end)
      floors = Enum.map(raw, &floor/1)
      left = round(total) - Enum.sum(floors)

      order =
        raw
        |> Enum.with_index()
        |> Enum.sort_by(fn {v, _i} -> -(v - floor(v)) end)
        |> Enum.map(fn {_v, i} -> i end)

      bump = order |> Stream.cycle() |> Enum.take(max(left, 0)) |> Enum.frequencies()

      floors
      |> Enum.with_index()
      |> Enum.map(fn {v, i} -> v + Map.get(bump, i, 0) end)
    end
  end

  @doc "Day-of-week bucket for a date: :fri | :sat | :sun | :weekday."
  def dow(%Date{} = date) do
    case Date.day_of_week(date) do
      5 -> :fri
      6 -> :sat
      7 -> :sun
      _ -> :weekday
    end
  end

  @doc "Deterministic noise in [0, 1) — same seed string, same stream, every boot."
  def noise_stream(seed, count) do
    state =
      :rand.seed_s(
        :exsss,
        {:erlang.phash2(seed, 1_000_000), :erlang.phash2({seed, :a}, 1_000_000),
         :erlang.phash2({seed, :b}, 1_000_000)}
      )

    {values, _} = Enum.map_reduce(1..count, state, fn _, s -> :rand.uniform_s(s) end)
    values
  end

  @doc "Weight profile for one bridge row across the days of a month."
  def weights_for(key, year, month, dim, seed) do
    noise = noise_stream("#{key}-#{seed}", dim)

    for day <- 1..dim do
      d = dow(Date.new!(year, month, day))
      n = 0.65 + Enum.at(noise, day - 1) * 0.75
      run = run_shape(day, d, dim) * n

      case key do
        k when k in [:new_sales, :upfront] ->
          week =
            case d do
              :fri -> 0.55
              :sat -> 1.35
              _ -> 1.0
            end

          tail = if day > dim - 4, do: 1.3, else: 1.0
          n * week * tail

        k when k in [:recurring, :defaults, :refunds, :cancel_within] ->
          run

        k when k in [:prior_default_collections, :defaults_recovered] ->
          0.6 * run + 0.4 * n

        _ ->
          n
      end
    end
  end
end
