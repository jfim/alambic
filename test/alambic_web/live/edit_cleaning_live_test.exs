defmodule AlambicWeb.EditCleaningLiveTest do
  use AlambicWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias Alambic.Cleanings
  alias Alambic.ReviewQueue

  setup :verify_on_exit!

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

  test "renders fresh editor when no revision exists", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn "abc" -> {:ok, "# Title\n\nbody"} end)

    {:ok, _view, html} = live(conn, ~p"/edit-cleaning/abc")

    assert html =~ "Edit cleaning"
    assert html =~ "abc"
    refute html =~ "Article text has changed"
    refute html =~ "Viewing rev"
  end

  test "pre-populates discard ranges from latest revision when hash matches", %{conn: conn} do
    text = "Hello sponsored world"
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, text} end)
    {:ok, _, :inserted} = Cleanings.save_revision("matched", text, [[6, 16]], source: "human")

    {:ok, _view, html} = live(conn, ~p"/edit-cleaning/matched")

    assert html =~ "Latest"
    assert html =~ "rev 1"
    # discarded substring rendered inside a discard span (high-contrast bg)
    assert html =~ ~r/bg-rose-\d+.*sponsored/s
  end

  test "shows drift banner when latest hash differs from live text", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "new text"} end)
    {:ok, _, :inserted} = Cleanings.save_revision("drift", "old text", [[0, 3]], source: "human")

    {:ok, _view, html} = live(conn, ~p"/edit-cleaning/drift")

    assert html =~ "Article text has changed"
  end

  test "add_span event merges into in-memory ranges", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "abcdefghij"} end)

    {:ok, view, _html} = live(conn, ~p"/edit-cleaning/spans")
    render_hook(view, "add_span", %{"start" => 1, "stop" => 4})
    render_hook(view, "add_span", %{"start" => 3, "stop" => 7})

    html = render(view)
    assert html =~ ~r/value="1"\s+name="start"/
    assert html =~ ~r/value="7"\s+name="stop"/
    refute html =~ ~r/value="4"\s+name="stop"/
  end

  test "delete_span removes a span by index", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "abcdefghij"} end)

    {:ok, view, _} = live(conn, ~p"/edit-cleaning/del")
    render_hook(view, "add_span", %{"start" => 0, "stop" => 3})
    render_hook(view, "add_span", %{"start" => 5, "stop" => 7})

    view |> element(~s|button[phx-value-index="0"][phx-click="delete_span"]|) |> render_click()

    html = render(view)
    refute html =~ ~r/value="0"\s+name="start"/
    assert html =~ ~r/value="5"\s+name="start"/
    assert html =~ ~r/value="7"\s+name="stop"/
  end

  test "edit_range validates and merges", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "abcdefghij"} end)

    {:ok, view, _} = live(conn, ~p"/edit-cleaning/edit")
    render_hook(view, "add_span", %{"start" => 0, "stop" => 3})
    render_hook(view, "edit_range", %{"index" => 0, "start" => 0, "stop" => 5})

    html = render(view)
    assert html =~ ~r/value="0"\s+name="start"/
    assert html =~ ~r/value="5"\s+name="stop"/

    # invalid (start >= stop) is a no-op
    render_hook(view, "edit_range", %{"index" => 0, "start" => 5, "stop" => 5})
    html = render(view)
    assert html =~ ~r/value="0"\s+name="start"/
    assert html =~ ~r/value="5"\s+name="stop"/
  end

  test "save inserts a revision and resolves the queue", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "abcdef"} end)
    {:ok, _} = ReviewQueue.enqueue(%{item_id: "sv", stage: :cleaning, confidence: 0.1, model_version: "v1"})

    {:ok, view, _} = live(conn, ~p"/edit-cleaning/sv")
    render_hook(view, "add_span", %{"start" => 0, "stop" => 3})
    view |> element("button", "Save") |> render_click()

    assert %{revision_id: 1, discard_ranges: [[0, 3]]} = Cleanings.latest("sv")
    assert ReviewQueue.list_pending() == []
  end

  test "save dedups identical (content, ranges) but still resolves queue", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "abcdef"} end)
    {:ok, _, :inserted} = Cleanings.save_revision("dedup", "abcdef", [[0, 3]], source: "human")
    {:ok, _} = ReviewQueue.enqueue(%{item_id: "dedup", stage: :cleaning, confidence: 0.1, model_version: "v1"})

    {:ok, view, _} = live(conn, ~p"/edit-cleaning/dedup")
    view |> element("button", "Save") |> render_click()

    assert [%{revision_id: 1}] = Cleanings.history("dedup")
    assert ReviewQueue.list_pending() == []
  end

  test "Prev shows historical revision read-only", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "current text"} end)
    {:ok, _, :inserted} = Cleanings.save_revision("hist", "old text", [[0, 3]], source: "human")
    {:ok, _, :inserted} = Cleanings.save_revision("hist", "current text", [[8, 12]], source: "human")

    {:ok, view, _} = live(conn, ~p"/edit-cleaning/hist")
    view |> element("button", "Prev") |> render_click()

    html = render(view)
    assert html =~ "Viewing rev 1"
    assert html =~ "old text"
    assert html =~ ~s|disabled|
  end

  test "shows confirmed-empty chip when latest revision has [] ranges and matches", %{conn: conn} do
    text = "no junk here"
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, text} end)
    {:ok, _, :inserted} = Cleanings.save_revision("empty-ok", text, [], source: "human")

    {:ok, _view, html} = live(conn, ~p"/edit-cleaning/empty-ok")
    assert html =~ "Confirmed: nothing to discard"
    refute html =~ "No spans yet"
  end

  test "shows unlabeled-empty placeholder when no revision exists", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "fresh article"} end)

    {:ok, _view, html} = live(conn, ~p"/edit-cleaning/fresh")
    assert html =~ "No spans yet"
    refute html =~ "Confirmed: nothing to discard"
  end

  test "save with empty ranges creates a confirmed-empty revision", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "confirm empty"} end)

    {:ok, view, _} = live(conn, ~p"/edit-cleaning/conf-empty")
    view |> element("button", "Save") |> render_click()

    assert %{revision_id: 1, discard_ranges: []} = Cleanings.latest("conf-empty")
  end

  test "renders error pane when Cham fetch fails", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:error, {:status, 404}} end)

    {:ok, _view, html} = live(conn, ~p"/edit-cleaning/missing")
    assert html =~ "Could not fetch"
  end
end
