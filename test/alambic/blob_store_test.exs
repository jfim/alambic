defmodule Alambic.BlobStoreTest do
  use ExUnit.Case, async: false

  alias Alambic.BlobStore

  setup do
    dir = Path.join(System.tmp_dir!(), "alambic_blobs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev = Application.get_env(:alambic, :blob_storage_path)
    Application.put_env(:alambic, :blob_storage_path, dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      Application.put_env(:alambic, :blob_storage_path, prev)
    end)

    %{dir: dir}
  end

  test "put returns the sha256 hex of raw bytes" do
    {:ok, sha} = BlobStore.put("hello world")
    assert sha == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
  end

  test "get round-trips raw bytes" do
    {:ok, sha} = BlobStore.put("payload")
    assert {:ok, "payload"} = BlobStore.get(sha)
  end

  test "get returns :not_found for missing sha" do
    assert :not_found = BlobStore.get(String.duplicate("0", 64))
  end

  test "delete removes the blob", %{dir: dir} do
    {:ok, sha} = BlobStore.put("byebye")
    assert :ok = BlobStore.delete(sha)
    refute File.exists?(Path.join(dir, "#{sha}.gz"))
    assert :not_found = BlobStore.get(sha)
  end

  test "put is idempotent for identical content" do
    {:ok, sha1} = BlobStore.put("same")
    {:ok, sha2} = BlobStore.put("same")
    assert sha1 == sha2
  end
end
