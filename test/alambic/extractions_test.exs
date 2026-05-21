defmodule Alambic.ExtractionsTest do
  use Alambic.DataCase, async: false

  alias Alambic.{BlobStore, Extractions}

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

  test "save_with_html stores blob and persists row with its sha" do
    {:ok, row} = Extractions.save_with_html(%{item_id: "it1", xpath: "/html"}, "<html></html>")

    assert row.content_sha256 ==
             :crypto.hash(:sha256, "<html></html>") |> Base.encode16(case: :lower)

    assert {:ok, "<html></html>"} = BlobStore.get(row.content_sha256)
  end

  test "delete removes row and blob" do
    {:ok, row} =
      Extractions.save_with_html(%{item_id: "it2", xpath: "/html"}, "<html>x</html>")

    :ok = Extractions.delete("it2")
    assert nil == Extractions.get("it2")
    assert :not_found = BlobStore.get(row.content_sha256)
  end
end
