defmodule Alambic.CleaningsTest do
  use Alambic.DataCase, async: false

  alias Alambic.{BlobStore, Cleanings}

  setup do
    dir = Path.join(System.tmp_dir!(), "alambic_blobs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev = Application.get_env(:alambic, :blob_storage_path)
    Application.put_env(:alambic, :blob_storage_path, dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.put_env(:alambic, :blob_storage_path, prev)
    end)

    :ok
  end

  test "save_with_text persists with content hash and ranges" do
    {:ok, row} =
      Cleanings.save_with_text(
        %{item_id: "c1", discard_ranges: [[0, 5], [10, 20]]},
        "Hello world this is text"
      )

    expected_sha =
      :crypto.hash(:sha256, "Hello world this is text") |> Base.encode16(case: :lower)

    assert row.content_sha256 == expected_sha
    assert row.discard_ranges == [[0, 5], [10, 20]]
  end

  test "save_with_text rejects overlapping or inverted ranges" do
    {:error, cs} =
      Cleanings.save_with_text(%{item_id: "c2", discard_ranges: [[5, 5]]}, "abc")

    refute cs.valid?
  end

  test "delete removes row and blob" do
    {:ok, row} = Cleanings.save_with_text(%{item_id: "c3", discard_ranges: []}, "abcdef")
    :ok = Cleanings.delete("c3")
    assert nil == Cleanings.get("c3")
    assert :not_found = BlobStore.get(row.content_sha256)
  end
end
