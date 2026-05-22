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

  test "save_with_text NFC-normalizes input so decomposed and composed forms share a blob" do
    composed = "café"
    decomposed = "café"
    refute composed == decomposed

    {:ok, a} = Cleanings.save_with_text(%{item_id: "nfc-a", discard_ranges: []}, composed)
    {:ok, b} = Cleanings.save_with_text(%{item_id: "nfc-b", discard_ranges: []}, decomposed)

    assert a.content_sha256 == b.content_sha256
    assert {:ok, ^composed} = BlobStore.get(a.content_sha256)
  end

  test "save_with_text rejects invalid UTF-8" do
    assert {:error, :invalid_utf8} =
             Cleanings.save_with_text(%{item_id: "bad", discard_ranges: []}, <<0xFF, 0xFE>>)
  end

  test "apply_discard_ranges operates on codepoints, not bytes" do
    # "héllo wörld" — each non-ASCII char is 2 bytes in UTF-8 but 1 codepoint.
    source = "héllo wörld"
    # Drop "héllo " (codepoints 0..6), keep "wörld".
    assert "wörld" == Cleanings.apply_discard_ranges(source, [[0, 6]])
    # Drop just the "ö" (codepoint index 7).
    assert "héllo wrld" == Cleanings.apply_discard_ranges(source, [[7, 8]])
  end
end
