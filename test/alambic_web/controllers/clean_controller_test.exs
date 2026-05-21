defmodule AlambicWeb.CleanControllerTest do
  use AlambicWeb.ConnCase, async: true

  alias Alambic.Models.Model
  alias Alambic.Repo

  defp seed_active(stage, version, path) do
    {:ok, m} =
      %Model{}
      |> Model.changeset(%{
        version: version,
        stage: stage,
        trained_at: DateTime.utc_now() |> DateTime.truncate(:second),
        artifact_path: path,
        status: :active
      })
      |> Repo.insert()

    m
  end

  test "POST /api/clean returns 503 when no active model and no saved row", %{conn: conn} do
    conn = post(conn, ~p"/api/clean", %{"item_id" => "x", "text" => "hi"})
    assert json_response(conn, 503) == %{"error" => "no model available"}
  end

  test "POST /api/clean returns model output when active model is present", %{conn: conn} do
    seed_active(:cleaning, "cleaning-dummy.1", "scripts/clean")
    conn = post(conn, ~p"/api/clean", %{"item_id" => "x", "text" => "hi"})

    assert %{
             "item_id" => "x",
             "cleaned_text" => "foo",
             "source" => "model",
             "model_version" => "cleaning-dummy.1"
           } = json_response(conn, 200)
  end

  test "POST /api/clean returns 422 on missing fields", %{conn: conn} do
    conn = post(conn, ~p"/api/clean", %{})
    assert json_response(conn, 422)
  end
end
