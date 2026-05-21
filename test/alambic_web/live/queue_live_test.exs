defmodule AlambicWeb.QueueLiveTest do
  use AlambicWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Alambic.ReviewQueue

  test "renders empty queue message", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/queue")
    assert html =~ "Review queue is empty"
  end

  test "lists pending items in ascending confidence order with links", %{conn: conn} do
    {:ok, _} =
      ReviewQueue.enqueue(%{
        item_id: "a",
        stage: :extraction,
        confidence: 0.4,
        model_version: "v1"
      })

    {:ok, _} =
      ReviewQueue.enqueue(%{
        item_id: "b",
        stage: :cleaning,
        confidence: 0.2,
        model_version: "v1"
      })

    {:ok, _view, html} = live(conn, ~p"/queue")
    assert html =~ "/edit-cleaning/b"
    assert html =~ "/edit-extraction/a"
    assert :binary.match(html, "/edit-cleaning/b") |> elem(0) <
             :binary.match(html, "/edit-extraction/a") |> elem(0)
  end
end
