defmodule Loom.Cron.ExprTest do
  use ExUnit.Case, async: true

  alias Loom.Cron.Expr

  defp next(text, from) do
    {:ok, expr} = Expr.parse(text)
    {:ok, at} = Expr.next(expr, from)
    at
  end

  test "every field form parses" do
    assert {:ok, e} = Expr.parse("*/15 9-17/2 1,15 jan-mar MON-fri")
    assert MapSet.to_list(e.minute) == [0, 15, 30, 45]
    assert MapSet.to_list(e.hour) == [9, 11, 13, 15, 17]
    assert MapSet.to_list(e.dom) == [1, 15]
    assert MapSet.to_list(e.month) == [1, 2, 3]
    assert MapSet.to_list(e.dow) == [1, 2, 3, 4, 5]

    assert {:ok, e} = Expr.parse("5/20 * * * 7")
    assert MapSet.to_list(e.minute) == [5, 25, 45]
    assert MapSet.to_list(e.dow) == [0]
  end

  test "malformed expressions are refused with a reason" do
    assert {:error, "a cron expression has 5 fields, got 4"} = Expr.parse("* * * *")
    assert {:error, "bad minute field: \"60\""} = Expr.parse("60 * * * *")
    assert {:error, _} = Expr.parse("*/0 * * * *")
    assert {:error, _} = Expr.parse("5-1 * * * *")
    assert {:error, _} = Expr.parse("@daily")
    assert {:error, _} = Expr.parse("* * * * * *")
  end

  test "next is strictly after, at minute resolution" do
    assert next("* * * * *", ~U[2026-10-16 08:30:00Z]) == ~U[2026-10-16 08:31:00Z]
    assert next("* * * * *", ~U[2026-10-16 08:30:59.9Z]) == ~U[2026-10-16 08:31:00Z]
    assert next("30 8 * * *", ~U[2026-10-16 08:30:00Z]) == ~U[2026-10-17 08:30:00Z]
  end

  test "rolls over hours, days, months and years" do
    assert next("0 0 * * *", ~U[2026-12-31 23:59:00Z]) == ~U[2027-01-01 00:00:00Z]
    assert next("0 9 1 * *", ~U[2026-10-16 10:00:00Z]) == ~U[2026-11-01 09:00:00Z]
    assert next("0 0 29 2 *", ~U[2026-10-16 00:00:00Z]) == ~U[2028-02-29 00:00:00Z]
  end

  test "weekdays" do
    # 2026-10-16 is a Friday.
    assert next("30 8 * * 1-5", ~U[2026-10-16 09:00:00Z]) == ~U[2026-10-19 08:30:00Z]
    assert next("0 22 * * 0", ~U[2026-10-16 09:00:00Z]) == ~U[2026-10-18 22:00:00Z]
  end

  test "two restricted day fields match either, as in Vixie cron" do
    # The 20th, or any Friday: Friday the 16th comes first.
    assert next("0 9 20 * 5", ~U[2026-10-15 00:00:00Z]) == ~U[2026-10-16 09:00:00Z]
    assert next("0 9 20 * 5", ~U[2026-10-17 00:00:00Z]) == ~U[2026-10-20 09:00:00Z]
  end

  test "an expression that can never match says so" do
    {:ok, expr} = Expr.parse("0 0 31 2 *")
    assert Expr.next(expr, ~U[2026-10-16 00:00:00Z]) == :none
  end
end
