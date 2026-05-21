defmodule Alambic.DatasetsTest do
  use Alambic.DataCase, async: false

  alias Alambic.{Cleanings, Datasets, Extractions}

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

  test "extraction parquet round-trips one row" do
    {:ok, _} = Extractions.save_with_html(%{item_id: "i1", xpath: "/html/body"}, "<html></html>")
    bytes = Datasets.export_parquet(:extraction) |> IO.iodata_to_binary()

    path = Path.join(System.tmp_dir!(), "alambic_t_#{System.unique_integer([:positive])}.parquet")
    File.write!(path, bytes)
    df = Explorer.DataFrame.from_parquet!(path)
    File.rm!(path)

    assert Explorer.DataFrame.n_rows(df) == 1
    row = Explorer.DataFrame.to_rows(df) |> hd()
    assert row["item_id"] == "i1"
    assert row["xpath"] == "/html/body"
    assert String.length(row["content_sha256"]) == 64
  end

  test "cleaning parquet carries discard_ranges as list of lists" do
    {:ok, _} =
      Cleanings.save_with_text(%{item_id: "c1", discard_ranges: [[0, 3], [7, 10]]}, "abcdefghij")

    bytes = Datasets.export_parquet(:cleaning) |> IO.iodata_to_binary()
    path = Path.join(System.tmp_dir!(), "alambic_t_#{System.unique_integer([:positive])}.parquet")
    File.write!(path, bytes)
    df = Explorer.DataFrame.from_parquet!(path)
    File.rm!(path)

    row = Explorer.DataFrame.to_rows(df) |> hd()
    assert row["item_id"] == "c1"
    assert row["discard_ranges"] == [[0, 3], [7, 10]]
  end

  test "empty stage returns valid empty parquet" do
    bytes = Datasets.export_parquet(:extraction) |> IO.iodata_to_binary()
    path = Path.join(System.tmp_dir!(), "alambic_t_#{System.unique_integer([:positive])}.parquet")
    File.write!(path, bytes)
    df = Explorer.DataFrame.from_parquet!(path)
    File.rm!(path)
    assert Explorer.DataFrame.n_rows(df) == 0
  end
end
