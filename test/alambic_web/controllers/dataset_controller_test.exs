defmodule AlambicWeb.DatasetControllerTest do
  use AlambicWeb.ConnCase, async: false

  alias Alambic.Extractions

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

  test "GET /api/datasets/extraction/rows.parquet returns parquet bytes", %{conn: conn} do
    {:ok, _} = Extractions.save_with_html(%{item_id: "i1", xpath: "/html"}, "<html/>")
    conn = get(conn, ~p"/api/datasets/extraction/rows.parquet")
    assert get_resp_header(conn, "content-type") |> hd() =~ "octet-stream"
    body = response(conn, 200)
    # parquet magic header
    assert binary_part(body, 0, 4) == "PAR1"
  end

  test "GET /api/datasets/extraction/blobs/:sha returns raw bytes", %{conn: conn} do
    {:ok, row} = Extractions.save_with_html(%{item_id: "i1", xpath: "/html"}, "<html>hi</html>")
    conn = get(conn, ~p"/api/datasets/extraction/blobs/#{row.content_sha256}")
    assert response(conn, 200) == "<html>hi</html>"
  end

  test "GET blob returns 404 for missing sha", %{conn: conn} do
    missing = String.duplicate("0", 64)
    conn = get(conn, ~p"/api/datasets/extraction/blobs/#{missing}")
    assert response(conn, 404)
  end

  test "GET rows for unknown stage returns 404", %{conn: conn} do
    conn = get(conn, ~p"/api/datasets/banana/rows.parquet")
    assert response(conn, 404)
  end
end
