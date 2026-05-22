defmodule Alambic.Cleanings.Ranges do
  @moduledoc """
  Pure helpers over a sorted, non-overlapping list of `[start, stop]` discard
  ranges. All public functions return a list in the same canonical form.
  """

  @type range :: [non_neg_integer()]
  @type t :: [range()]

  @spec merge_in(t(), range()) :: t()
  def merge_in(ranges, [start, stop]) when not (is_integer(start) and is_integer(stop) and start >= 0 and stop > start) do
    ranges
  end

  def merge_in(ranges, [start, stop]) do
    [[start, stop] | ranges]
    |> Enum.sort_by(fn [s, _] -> s end)
    |> coalesce()
  end

  @spec remove(t(), integer()) :: t()
  def remove(ranges, index) when is_integer(index) and index >= 0 and index < length(ranges) do
    List.delete_at(ranges, index)
  end

  def remove(ranges, _index), do: ranges

  @spec replace(t(), non_neg_integer(), range()) :: t()
  def replace(ranges, index, [start, stop])
      when is_integer(start) and is_integer(stop) and start >= 0 and stop > start and
             is_integer(index) and index >= 0 and index < length(ranges) do
    ranges
    |> List.replace_at(index, [start, stop])
    |> Enum.sort_by(fn [s, _] -> s end)
    |> coalesce()
  end

  def replace(ranges, _index, _new), do: ranges

  defp coalesce([]), do: []
  defp coalesce([first | rest]), do: do_coalesce(rest, [first])

  defp do_coalesce([], acc), do: Enum.reverse(acc)

  defp do_coalesce([[s, e] | rest], [[ps, pe] | tail]) when s <= pe do
    do_coalesce(rest, [[ps, max(pe, e)] | tail])
  end

  defp do_coalesce([next | rest], acc), do: do_coalesce(rest, [next | acc])
end
