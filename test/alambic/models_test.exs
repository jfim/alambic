defmodule Alambic.ModelsTest do
  use Alambic.DataCase, async: true

  alias Alambic.Models
  alias Alambic.Models.Model

  describe "list/0" do
    test "returns all registered models" do
      assert Models.list() == []
      {:ok, _} = insert_model(%{version: "v1", stage: :extraction, status: :active})
      assert [%Model{version: "v1"}] = Models.list()
    end
  end

  describe "active_for/1" do
    test "returns the active model for a stage, or nil" do
      assert Models.active_for(:extraction) == nil
      {:ok, _} = insert_model(%{version: "v1", stage: :extraction, status: :active})
      {:ok, _} = insert_model(%{version: "v2", stage: :extraction, status: :retired})
      assert %Model{version: "v1"} = Models.active_for(:extraction)
    end
  end

  describe "activate/1" do
    test "promotes a model and retires the previously active one in the same stage" do
      {:ok, old} = insert_model(%{version: "old", stage: :extraction, status: :active})
      {:ok, new} = insert_model(%{version: "new", stage: :extraction, status: :retired})

      {:ok, %Model{version: "new", status: :active}} = Models.activate("new")

      assert Alambic.Repo.get!(Model, old.version).status == :retired
      assert Alambic.Repo.get!(Model, new.version).status == :active
    end

    test "returns {:error, :not_found} for unknown versions" do
      assert Models.activate("nope") == {:error, :not_found}
    end
  end

  defp insert_model(attrs) do
    defaults = %{
      trained_at: DateTime.utc_now() |> DateTime.truncate(:second),
      artifact_path: "scripts/extract",
      training_sample_size: 0
    }

    %Model{}
    |> Model.changeset(Map.merge(defaults, attrs))
    |> Alambic.Repo.insert()
  end
end
