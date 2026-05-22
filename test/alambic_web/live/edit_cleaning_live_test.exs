defmodule AlambicWeb.EditCleaningLiveTest do
  use AlambicWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mox

  alias Alambic.Cleanings
  alias Alambic.ReviewQueue

  setup :verify_on_exit!

  test "renders fetched HTML and a placeholder annotation pane", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_extraction_html, fn _ -> {:ok, "<html/>"} end)

    {:ok, _view, html} = live(conn, ~p"/edit-cleaning/abc")
    assert html =~ "Token annotation"
  end

  test "confirm writes a cleaning and resolves the queue", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_extraction_html, fn _ -> {:ok, "<html/>"} end)

    {:ok, _} =
      ReviewQueue.enqueue(%{
        item_id: "abc",
        stage: :cleaning,
        confidence: 0.1,
        model_version: "v1"
      })

    {:ok, view, _html} = live(conn, ~p"/edit-cleaning/abc")
    view |> element("button", "Confirm") |> render_click()

    assert %Alambic.Cleanings.Revision{} = Cleanings.latest("abc")
    assert ReviewQueue.list_pending() == []
  end
end
