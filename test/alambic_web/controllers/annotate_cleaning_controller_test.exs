defmodule AlambicWeb.AnnotateCleaningControllerTest do
  use AlambicWeb.ConnCase, async: false

  alias Alambic.ReviewQueue

  test "redirects to /edit-cleaning/:item_id?after=annotate when work is pending", %{conn: conn} do
    {:ok, _} =
      ReviewQueue.enqueue(%{
        item_id: "low",
        stage: :cleaning,
        confidence: 0.1,
        model_version: "v1"
      })

    conn = get(conn, ~p"/annotate-cleaning")
    assert redirected_to(conn) == "/edit-cleaning/low?after=annotate"
  end

  test "renders the all-done page when the queue is empty", %{conn: conn} do
    conn = get(conn, ~p"/annotate-cleaning")
    assert html_response(conn, 200) =~ "All annotated"
  end
end
