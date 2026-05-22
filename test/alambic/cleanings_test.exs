defmodule Alambic.CleaningsTest do
  use Alambic.DataCase, async: false

  alias Alambic.{BlobStore, Cleanings}
  alias Alambic.Cleanings.Revision

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

  test "save_revision inserts the first revision as #1" do
    {:ok, %Revision{revision_id: 1} = rev, :inserted} =
      Cleanings.save_revision("item-a", "hello world", [[0, 5]])

    assert rev.discard_ranges == [[0, 5]]
    assert {:ok, "hello world"} = BlobStore.get(rev.content_sha256)
  end

  test "save_revision dedups identical (content_sha256, discard_ranges)" do
    {:ok, %Revision{revision_id: 1}, :inserted} =
      Cleanings.save_revision("item-b", "same text", [[0, 4]])

    {:ok, %Revision{revision_id: 1}, :unchanged} =
      Cleanings.save_revision("item-b", "same text", [[0, 4]])

    assert length(Cleanings.history("item-b")) == 1
  end

  test "save_revision allocates the next revision_id on a change" do
    {:ok, %Revision{revision_id: 1}, :inserted} =
      Cleanings.save_revision("item-c", "text one", [])

    {:ok, %Revision{revision_id: 2}, :inserted} =
      Cleanings.save_revision("item-c", "text one", [[0, 4]])

    {:ok, %Revision{revision_id: 3}, :inserted} =
      Cleanings.save_revision("item-c", "text two", [[0, 4]])

    history = Cleanings.history("item-c")
    assert Enum.map(history, & &1.revision_id) == [1, 2, 3]
  end

  test "latest returns the highest revision_id for the item" do
    {:ok, _, :inserted} = Cleanings.save_revision("item-d", "first", [])
    {:ok, _, :inserted} = Cleanings.save_revision("item-d", "second", [])

    assert %Revision{revision_id: 2} = Cleanings.latest("item-d")
  end

  test "latest returns nil for unknown item" do
    assert nil == Cleanings.latest("nope")
  end

  test "save_revision NFC-normalizes text before hashing" do
    composed = "café"
    decomposed = "café"

    {:ok, %Revision{content_sha256: sha1}, :inserted} =
      Cleanings.save_revision("item-e", composed, [])

    {:ok, %Revision{content_sha256: sha2}, _} =
      Cleanings.save_revision("item-e", decomposed, [])

    assert sha1 == sha2
  end

  test "save_revision rejects invalid UTF-8" do
    assert {:error, :invalid_utf8} =
             Cleanings.save_revision("item-f", <<0xFF, 0xFE, 0xFD>>, [])
  end

  test "apply_discard_ranges slices by codepoint" do
    assert Cleanings.apply_discard_ranges("ABCDEFG", [[1, 3], [5, 6]]) == "ADEG"
  end

  test "delete_all removes all revisions and their blobs" do
    {:ok, r1, :inserted} = Cleanings.save_revision("item-g", "alpha", [])
    {:ok, r2, :inserted} = Cleanings.save_revision("item-g", "beta", [])

    :ok = Cleanings.delete_all("item-g")

    assert Cleanings.history("item-g") == []
    assert :not_found = BlobStore.get(r1.content_sha256)
    assert :not_found = BlobStore.get(r2.content_sha256)
  end

  test "Revision changeset requires source and rejects unknown values" do
    base = %{
      item_id: "x",
      revision_id: 1,
      content_sha256: String.duplicate("a", 64),
      discard_ranges: []
    }

    cs = Alambic.Cleanings.Revision.changeset(%Alambic.Cleanings.Revision{}, base)
    refute cs.valid?
    assert {"can't be blank", _} = cs.errors[:source]

    cs2 = Alambic.Cleanings.Revision.changeset(%Alambic.Cleanings.Revision{}, Map.put(base, :source, "bogus"))
    refute cs2.valid?
    assert cs2.errors[:source]

    cs3 = Alambic.Cleanings.Revision.changeset(%Alambic.Cleanings.Revision{}, Map.put(base, :source, "human"))
    assert cs3.valid?
  end
end
