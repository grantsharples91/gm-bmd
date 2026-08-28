defmodule GmBmd.Format do
  @moduledoc "Number formatting shared by the domain and the screens."

  @doc "Round and thousands-separate: 12073 → \"12,073\"."
  def num(value) do
    value
    |> round()
    |> abs()
    |> Integer.to_string()
    |> group_thousands()
    |> then(fn s -> if round(value) < 0, do: "-" <> s, else: s end)
  end

  @doc "Signed count: +1,204 / −310 / 0."
  def signed(value) do
    r = round(value)

    cond do
      r > 0 -> "+" <> num(r)
      r < 0 -> "−" <> num(abs(r))
      true -> "0"
    end
  end

  def aed(value), do: "AED " <> num(value)

  def aed_short(value) do
    abs_v = abs(value)

    cond do
      abs_v >= 1_000_000 -> "AED #{:erlang.float_to_binary(value / 1_000_000, decimals: 2)}m"
      abs_v >= 10_000 -> "AED #{num(value / 1000)}k"
      true -> aed(value)
    end
  end

  @doc "Share as a percentage: 0.685 → \"68.5%\"."
  def pct(value) when value == 0, do: "0%"
  def pct(value), do: "#{:erlang.float_to_binary(value * 100 / 1, decimals: 1)}%"

  def pct0(value), do: "#{round(value * 100)}%"

  @doc "Signed percentage from a share: 0.031 → \"+3.1%\"."
  def signed_pct(value) do
    sign =
      cond do
        value > 0 -> "+"
        value < 0 -> "−"
        true -> ""
      end

    "#{sign}#{:erlang.float_to_binary(abs(value) * 100 / 1, decimals: 1)}%"
  end

  defp group_thousands(digits) do
    digits
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map(&List.to_string/1)
    |> Enum.join(",")
  end
end
