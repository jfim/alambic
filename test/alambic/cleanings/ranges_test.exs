defmodule Alambic.Cleanings.RangesTest do
  use ExUnit.Case, async: true

  alias Alambic.Cleanings.Ranges

  describe "merge_in/2" do
    test "adds a disjoint range" do
      assert Ranges.merge_in([[0, 3], [10, 15]], [5, 7]) == [[0, 3], [5, 7], [10, 15]]
    end

    test "merges overlapping ranges into one" do
      assert Ranges.merge_in([[0, 5]], [3, 10]) == [[0, 10]]
    end

    test "merges touching ranges" do
      assert Ranges.merge_in([[0, 5]], [5, 10]) == [[0, 10]]
    end

    test "swallows a range fully inside an existing one" do
      assert Ranges.merge_in([[0, 20]], [5, 10]) == [[0, 20]]
    end

    test "merges across multiple adjacent ranges" do
      assert Ranges.merge_in([[0, 3], [5, 8], [10, 12]], [2, 11]) == [[0, 12]]
    end

    test "ignores zero-width and inverted ranges" do
      assert Ranges.merge_in([[0, 5]], [3, 3]) == [[0, 5]]
      assert Ranges.merge_in([[0, 5]], [7, 3]) == [[0, 5]]
    end

    test "result is sorted ascending" do
      assert Ranges.merge_in([], [10, 12]) == [[10, 12]]
      assert Ranges.merge_in([[10, 12]], [0, 3]) == [[0, 3], [10, 12]]
    end
  end

  describe "remove/2" do
    test "removes by index" do
      assert Ranges.remove([[0, 3], [5, 8], [10, 12]], 1) == [[0, 3], [10, 12]]
    end

    test "out-of-bounds index is a no-op" do
      assert Ranges.remove([[0, 3]], 5) == [[0, 3]]
      assert Ranges.remove([[0, 3]], -1) == [[0, 3]]
    end
  end

  describe "replace/3" do
    test "replaces a range and re-merges" do
      assert Ranges.replace([[0, 3], [10, 15]], 0, [0, 11]) == [[0, 15]]
    end

    test "rejects an invalid replacement (returns input)" do
      assert Ranges.replace([[0, 3]], 0, [5, 5]) == [[0, 3]]
      assert Ranges.replace([[0, 3]], 0, [-1, 4]) == [[0, 3]]
    end

    test "out-of-bounds index is a no-op" do
      assert Ranges.replace([[0, 3]], 99, [5, 7]) == [[0, 3]]
    end
  end
end
