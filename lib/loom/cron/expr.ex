defmodule Loom.Cron.Expr do
  @moduledoc """
  Standard five-field cron expressions, always in UTC.

      ┌───────── minute        0-59
      │ ┌─────── hour          0-23
      │ │ ┌───── day of month  1-31
      │ │ │ ┌─── month         1-12 or JAN-DEC
      │ │ │ │ ┌─ day of week   0-7 or SUN-SAT (0 and 7 are both Sunday)
      * * * * *

  Each field is a comma list of `*`, `n`, `a-b`, any of those with `/step`, or
  `n/step` (from `n` to the field's end). As in Vixie cron, when both day
  fields are restricted a day matches if *either* does: `0 9 13 * 5` is every
  13th and every Friday, not Fridays the 13th.

  Nothing else: no `@daily`, no seconds field, no `L`/`W`/`#`. Hand-written
  rather than a dependency because this is all of it.
  """

  @fields [
    minute: {0, 59},
    hour: {0, 23},
    dom: {1, 31},
    month: {1, 12},
    dow: {0, 7}
  ]

  @names %{
    month: ~w(jan feb mar apr may jun jul aug sep oct nov dec) |> Enum.with_index(1) |> Map.new(),
    dow: ~w(sun mon tue wed thu fri sat) |> Enum.with_index() |> Map.new()
  }

  # Far enough for any expression that can match at all (Feb 29 recurs within
  # eight years); an expression that cannot, like `0 0 31 2 *`, ends here.
  @horizon_days 366 * 8

  @doc """
  Parse an expression. Returns `{:ok, expr}` or `{:error, reason}` with a
  sentence fit to show the user.
  """
  def parse(text) when is_binary(text) do
    case String.split(text) do
      parts when length(parts) == 5 ->
        @fields
        |> Enum.zip(parts)
        |> Enum.reduce_while({:ok, %{}}, fn {{field, range}, part}, {:ok, acc} ->
          case parse_field(field, range, String.downcase(part)) do
            {:ok, set} -> {:cont, {:ok, Map.put(acc, field, set)}}
            :error -> {:halt, {:error, "bad #{field} field: #{inspect(part)}"}}
          end
        end)
        |> case do
          {:ok, expr} ->
            {:ok,
             expr
             |> Map.update!(:dow, &normalize_sunday/1)
             |> Map.put(:dom_any?, String.starts_with?(Enum.at(parts, 2), "*"))
             |> Map.put(:dow_any?, String.starts_with?(Enum.at(parts, 4), "*"))}

          error ->
            error
        end

      parts ->
        {:error, "a cron expression has 5 fields, got #{length(parts)}"}
    end
  end

  def parse(_other), do: {:error, "a cron expression is a string"}

  @doc """
  The first minute strictly after `from` that the expression matches, as a
  UTC `DateTime`. `:none` if it never matches.
  """
  def next(expr, %DateTime{} = from) do
    start =
      from
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)
      |> Map.put(:second, 0)
      |> NaiveDateTime.add(60)

    search(expr, start, NaiveDateTime.add(start, @horizon_days, :day))
  end

  # Coarsest field first: a month that cannot match skips to the next month
  # instead of walking it a minute at a time.
  defp search(expr, t, horizon) do
    cond do
      NaiveDateTime.compare(t, horizon) == :gt ->
        :none

      t.month not in expr.month ->
        search(expr, first_of_next_month(t), horizon)

      not day?(expr, NaiveDateTime.to_date(t)) ->
        search(expr, %{NaiveDateTime.add(t, 1, :day) | hour: 0, minute: 0}, horizon)

      t.hour not in expr.hour ->
        search(expr, %{NaiveDateTime.add(t, 1, :hour) | minute: 0}, horizon)

      t.minute not in expr.minute ->
        search(expr, NaiveDateTime.add(t, 60), horizon)

      true ->
        {:ok, DateTime.from_naive!(t, "Etc/UTC")}
    end
  end

  defp first_of_next_month(%{year: y, month: 12} = t),
    do: %{t | year: y + 1, month: 1, day: 1, hour: 0, minute: 0}

  defp first_of_next_month(%{month: m} = t), do: %{t | month: m + 1, day: 1, hour: 0, minute: 0}

  defp day?(expr, date) do
    dom? = date.day in expr.dom
    # `Date.day_of_week/1` is 1 (Monday) … 7 (Sunday); cron's Sunday is 0.
    dow? = rem(Date.day_of_week(date), 7) in expr.dow

    case {expr.dom_any?, expr.dow_any?} do
      {true, true} -> true
      {true, false} -> dow?
      {false, true} -> dom?
      {false, false} -> dom? or dow?
    end
  end

  defp normalize_sunday(set) do
    if 7 in set, do: set |> MapSet.delete(7) |> MapSet.put(0), else: set
  end

  defp parse_field(field, range, part) do
    part
    |> String.split(",")
    |> Enum.reduce_while({:ok, MapSet.new()}, fn item, {:ok, acc} ->
      case parse_item(field, range, item) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, MapSet.new(values))}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp parse_item(field, {lo, hi} = range, item) do
    {base, step, stepped?} =
      case String.split(item, "/") do
        [base] -> {base, {:ok, 1}, false}
        [base, step] -> {base, integer(step), true}
        _ -> {item, :error, false}
      end

    with {:ok, step} when step > 0 <- step,
         {:ok, first, last} <- span(field, range, base, stepped?),
         true <- lo <= first and first <= last and last <= hi do
      {:ok, Enum.take_every(first..last, step)}
    else
      _ -> :error
    end
  end

  # `n/step` runs from n to the end of the field, as in Vixie cron.
  defp span(_field, {lo, hi}, "*", _stepped?), do: {:ok, lo, hi}

  defp span(field, {_lo, hi}, base, stepped?) do
    case String.split(base, "-") do
      [a, b] ->
        with {:ok, a} <- value(field, a), {:ok, b} <- value(field, b), do: {:ok, a, b}

      [a] ->
        with {:ok, a} <- value(field, a), do: {:ok, a, if(stepped?, do: hi, else: a)}

      _ ->
        :error
    end
  end

  defp value(field, text) do
    case Map.fetch(Map.get(@names, field, %{}), text) do
      {:ok, n} -> {:ok, n}
      :error -> integer(text)
    end
  end

  defp integer(text) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end
end
