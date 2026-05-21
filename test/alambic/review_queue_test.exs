defmodule Alambic.ReviewQueueTest do
  use Alambic.DataCase, async: true

  alias Alambic.ReviewQueue
  alias Alambic.ReviewQueue.Entry

  test "enqueue/1 inserts a pending row; resolve/2 sets resolved_at" do
    attrs = %{item_id: "abc", stage: :extraction, confidence: 0.4, model_version: "v1"}
    {:ok, %Entry{resolved_at: nil}} = ReviewQueue.enqueue(attrs)

    assert [%Entry{item_id: "abc"}] = ReviewQueue.list_pending()

    :ok = ReviewQueue.resolve("abc", :extraction)
    assert ReviewQueue.list_pending() == []
  end

  test "list_pending/0 orders by ascending confidence" do
    for {id, c} <- [{"a", 0.9}, {"b", 0.1}, {"c", 0.5}] do
      {:ok, _} =
        ReviewQueue.enqueue(%{item_id: id, stage: :extraction, confidence: c, model_version: "v1"})
    end

    assert ["b", "c", "a"] = Enum.map(ReviewQueue.list_pending(), & &1.item_id)
  end

  test "enqueue/1 is idempotent on (item_id, stage)" do
    attrs = %{item_id: "x", stage: :extraction, confidence: 0.3, model_version: "v1"}
    {:ok, _} = ReviewQueue.enqueue(attrs)
    {:ok, _} = ReviewQueue.enqueue(%{attrs | confidence: 0.5})
    assert [%Entry{confidence: 0.5}] = ReviewQueue.list_pending()
  end
end
