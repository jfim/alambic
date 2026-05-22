defmodule Alambic.InferenceTest do
  use Alambic.DataCase, async: false

  alias Alambic.Cleanings
  alias Alambic.Extractions
  alias Alambic.Inference
  alias Alambic.Models.Model
  alias Alambic.Repo
  alias Alambic.ReviewQueue

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
    {:ok, _} = Extractions.save_with_html(%{item_id: "x", xpath: "/saved"}, "<h/>")

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

  test "clean/2 returns kept text after discarding ranges" do
    {:ok, _, :inserted} =
      Cleanings.save_revision("x1", "drop me keep me", [[0, 8]])

    assert {:ok, %{cleaned_text: "keep me", source: :saved}} = Inference.clean("x1", "ignored")
  end

  test "clean/2 returns full source when no ranges" do
    {:ok, _, :inserted} = Cleanings.save_revision("x", "hi", [])
    assert {:ok, %{item_id: "x", source: :saved, cleaned_text: "hi"}} = Inference.clean("x", "hi")
  end

  test "clean/2 invokes active cleaning script when no saved row" do
    seed_active_model(:cleaning, "cleaning-dummy.1", "scripts/clean")
    assert {:ok, %{cleaned_text: "foo", source: :model}} = Inference.clean("x", "ignored")
  end
end
