defmodule Alambic.Cham.HTTPTest do
  use ExUnit.Case, async: true

  alias Alambic.Cham.HTTP

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  test "fetch_extraction_html/1 hits /api/v1/items/:id/files/:filename and returns the body",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "GET", "/api/v1/items/abc/files/original.html", fn conn ->
      Plug.Conn.resp(conn, 200, "<html>hi</html>")
    end)

    assert {:ok, "<html>hi</html>"} =
             HTTP.fetch_extraction_html("abc", base_url: base_url, filename: "original.html")
  end

  test "fetch_extraction_html/1 returns {:error, :not_found} on 404",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "GET", "/api/v1/items/abc/files/original.html", fn conn ->
      Plug.Conn.resp(conn, 404, "")
    end)

    assert {:error, {:status, 404}} =
             HTTP.fetch_extraction_html("abc", base_url: base_url, filename: "original.html")
  end

  test "fetch_cleaning_content/1 hits /api/v1/items/:id/files/:filename and returns the body",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "GET", "/api/v1/items/abc/files/content.md", fn conn ->
      Plug.Conn.resp(conn, 200, "# Cleaned Content\n")
    end)

    assert {:ok, "# Cleaned Content\n"} =
             HTTP.fetch_cleaning_content("abc", base_url: base_url, filename: "content.md")
  end

  test "fetch_cleaning_content/1 returns {:error, :not_found} on 404",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "GET", "/api/v1/items/abc/files/content.md", fn conn ->
      Plug.Conn.resp(conn, 404, "")
    end)

    assert {:error, {:status, 404}} =
             HTTP.fetch_cleaning_content("abc", base_url: base_url, filename: "content.md")
  end
end
