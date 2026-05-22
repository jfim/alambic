defmodule AlambicWeb.EditExtractionLiveTest do
  use AlambicWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mox

  alias Alambic.Extractions
  alias Alambic.ReviewQueue

  setup :verify_on_exit!

  test "renders sanitized fetched HTML inline", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_extraction_html, fn "abc" ->
      {:ok, ~s{<html><body><p>hi</p><script>alert(1)</script></body></html>}}
    end)

    {:ok, _view, html} = live(conn, ~p"/edit-extraction/abc")
    assert html =~ "<p>hi</p>"
    refute html =~ "alert(1)"
    refute html =~ ~s[<script>alert]
  end

  test "renders a fetch error when Cham fails", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_extraction_html, fn _ -> {:error, {:status, 404}} end)

    {:ok, _view, html} = live(conn, ~p"/edit-extraction/missing")
    assert html =~ "Could not fetch HTML"
  end

  test "confirm writes an extraction and resolves the queue", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_extraction_html, fn _ -> {:ok, "<html/>"} end)

    {:ok, _} =
      ReviewQueue.enqueue(%{
        item_id: "abc",
        stage: :extraction,
        confidence: 0.1,
        model_version: "v1"
      })

    {:ok, view, _html} = live(conn, ~p"/edit-extraction/abc")
    view |> element("button", "Confirm") |> render_click()

    assert %{xpath: "/html/body"} = Extractions.get("abc")
    assert ReviewQueue.list_pending() == []
  end
end
