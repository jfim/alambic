defmodule AlambicWeb.Admin.ModelControllerTest do
  use AlambicWeb.ConnCase, async: true

  alias Alambic.Models.Model
  alias Alambic.Repo

  defp insert(attrs) do
    %Model{}
    |> Model.changeset(
      Map.merge(
        %{
          trained_at: DateTime.utc_now() |> DateTime.truncate(:second),
          artifact_path: "scripts/extract",
          status: :retired
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  test "GET /api/models lists models", %{conn: conn} do
    insert(%{version: "v1", stage: :extraction, status: :active})
    insert(%{version: "v2", stage: :cleaning, status: :retired})

    conn = get(conn, ~p"/api/models")
    body = json_response(conn, 200)
    assert length(body) == 2
    assert Enum.find(body, &(&1["version"] == "v1"))["status"] == "active"
  end

  test "POST /api/models/:version/activate promotes it", %{conn: conn} do
    insert(%{version: "v1", stage: :extraction, status: :active})
    insert(%{version: "v2", stage: :extraction, status: :retired})

    conn = post(conn, ~p"/api/models/v2/activate")

    assert %{"version" => "v2", "status" => "active"} = json_response(conn, 200)
    assert Repo.get!(Model, "v1").status == :retired
  end

  test "POST /api/models/:version/activate returns 404 for unknown version", %{conn: conn} do
    conn = post(conn, ~p"/api/models/missing/activate")
    assert json_response(conn, 404)
  end
end
