defmodule GmBmd.FormatTest do
  use ExUnit.Case, async: true

  alias GmBmd.Format

  test "num groups thousands" do
    assert Format.num(0) == "0"
    assert Format.num(999) == "999"
    assert Format.num(1000) == "1,000"
    assert Format.num(12_073.4) == "12,073"
    assert Format.num(-1_234_567) == "-1,234,567"
  end

  test "signed" do
    assert Format.signed(5) == "+5"
    assert Format.signed(-5) == "−5"
    assert Format.signed(0) == "0"
  end

  test "aed short" do
    assert Format.aed_short(950) == "AED 950"
    assert Format.aed_short(25_000) == "AED 25k"
    assert Format.aed_short(1_250_000) == "AED 1.25m"
  end

  test "pct" do
    assert Format.pct(0) == "0%"
    assert Format.pct(0.685) == "68.5%"
    assert Format.pct0(0.685) == "69%"
    assert Format.signed_pct(0.031) == "+3.1%"
    assert Format.signed_pct(-0.031) == "−3.1%"
  end
end
