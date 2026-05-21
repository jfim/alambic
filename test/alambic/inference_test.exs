defmodule Alambic.InferenceTest do
  use Alambic.DataCase, async: true

  alias Alambic.Extractions
  alias Alambic.Inference
  alias Alambic.Models.Model
  alias Alambic.ReviewQueue
  alias Alambic.Repo

  defp seed_active_model(stage, version, path) do
    {:ok, m} =
      %Model{}
      |> Model.changeset(%{
        version: version,
        stage: stage,
        trained_at: DateTime.utc_now() |> DateTime.truncate(:second),
        artifact_path: path,
        status: :active,
        training_sample_size: 0
      })
      |> Repo.insert()

    m
  end

  test "extract/2 returns saved row when present" do
    {:ok, _} = Extractions.save(%{item_id: "x", xpath: "/saved", html_snapshot: "<h/>"})

    assert {:ok,
            %{
              item_id: "x",
              xpath: "/saved",
              source: :saved,
              model_version: nil,
              confidence: nil
            }} = Inference.extract("x", "<ignored/>")
  end

  test "extract/2 invokes the active extraction script when no saved row" do
    seed_active_model(:extraction, "extraction-dummy.1", "scripts/extract")

    assert {:ok,
            %{
              item_id: "x",
              xpath: "/",
              source: :model,
              model_version: "extraction-dummy.1",
              confidence: nil
            }} = Inference.extract("x", "<html/>")
  end

  test "extract/2 returns 503 when no active model and no saved row" do
    assert {:error, :no_model} = Inference.extract("x", "<html/>")
  end

  test "extract/2 enqueues review when confidence below threshold" do
    seed_active_model(:extraction, "v1", "test/support/fixtures/low_confidence_extract")
    Application.put_env(:alambic, :review_confidence_threshold, 0.9)

    {:ok, _} = Inference.extract("x", "<html/>")
    assert [%{item_id: "x", stage: :extraction}] = ReviewQueue.list_pending()
  after
    Application.put_env(:alambic, :review_confidence_threshold, 0.7)
  end

  test "clean/2 returns saved row when present" do
    {:ok, _} =
      Alambic.Cleanings.save(%{
        item_id: "x",
        token_labels: [%{"token" => "hi", "label" => "keep"}],
        source_text: "hi"
      })

    assert {:ok, %{item_id: "x", source: :saved, cleaned_text: "hi"}} = Inference.clean("x", "hi")
  end

  test "clean/2 invokes active cleaning script when no saved row" do
    seed_active_model(:cleaning, "cleaning-dummy.1", "scripts/clean")
    assert {:ok, %{cleaned_text: "foo", source: :model}} = Inference.clean("x", "ignored")
  end
end
