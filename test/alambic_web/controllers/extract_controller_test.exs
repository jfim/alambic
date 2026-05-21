defmodule AlambicWeb.ExtractControllerTest do
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

  test "POST /api/extract returns 503 when no active model and no saved row", %{conn: conn} do
    conn = post(conn, ~p"/api/extract", %{"item_id" => "x", "html" => "<html/>"})
    assert json_response(conn, 503) == %{"error" => "no model available"}
  end

  test "POST /api/extract returns the model's prediction", %{conn: conn} do
    seed_active(:extraction, "extraction-dummy.1", "scripts/extract")

    conn = post(conn, ~p"/api/extract", %{"item_id" => "x", "html" => "<html/>"})

    assert %{
             "item_id" => "x",
             "xpath" => "/",
             "source" => "model",
             "model_version" => "extraction-dummy.1",
             "confidence" => nil
           } = json_response(conn, 200)
  end

  test "POST /api/extract returns 422 on missing fields", %{conn: conn} do
    conn = post(conn, ~p"/api/extract", %{})
    assert json_response(conn, 422)
  end
end
