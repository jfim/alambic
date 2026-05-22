defmodule Alambic.Inference do
  @moduledoc """
  Saved-vs-model dispatch for both stages. Owns confidence-based queueing.

  On success returns a map with the spec-shaped response. Real Python scripts
  emit a JSON object on stdout; the facade attaches `model_version` and `source`.
  """

  alias Alambic.{Cleanings, Extractions, Models, ReviewQueue, ScriptRunner}

  @script_timeout 30_000

  def extract(item_id, html) do
    case Extractions.get(item_id) do
      %{xpath: xpath} ->
        {:ok,
         %{
           item_id: item_id,
           xpath: xpath,
           source: :saved,
           model_version: nil,
           confidence: nil
         }}

      nil ->
        run_model(:extraction, item_id, html, &decode_extract/1)
    end
  end

  def clean(item_id, text) do
    case Cleanings.latest(item_id) do
      %{content_sha256: sha, discard_ranges: ranges} ->
        respond_with_saved(item_id, sha, ranges, :saved)

      nil ->
        case Cleanings.find_latest_by_text(text) do
          %{content_sha256: sha, discard_ranges: ranges} ->
            respond_with_saved(item_id, sha, ranges, :saved_by_content)

          nil ->
            run_model(:cleaning, item_id, text, &decode_clean/1)
        end
    end
  end

  defp respond_with_saved(item_id, sha, ranges, source) do
    {:ok, blob} = Alambic.BlobStore.get(sha)
    cleaned = Cleanings.apply_discard_ranges(blob, ranges)

    {:ok,
     %{
       item_id: item_id,
       cleaned_text: cleaned,
       source: source,
       model_version: nil,
       confidence: nil
     }}
  end

  defp run_model(stage, item_id, input, decoder) do
    case Models.active_for(stage) do
      nil ->
        {:error, :no_model}

      %{version: version, artifact_path: artifact_path} ->
        path = write_temp_input(input)

        try do
          case ScriptRunner.run_sync("uv", ["run", Path.join(artifact_path, "main.py"), path],
                 timeout: @script_timeout
               ) do
            {:ok, output, 0} ->
              payload = output |> String.trim() |> Jason.decode!()

              response =
                decoder.(payload)
                |> Map.merge(%{item_id: item_id, source: :model, model_version: version})

              maybe_enqueue(stage, item_id, response, version)
              {:ok, response}

            {:ok, _output, status} ->
              {:error, {:script_failed, status}}

            {:error, :timeout, _, _} ->
              {:error, :timeout}
          end
        after
          File.rm(path)
        end
    end
  end

  defp decode_extract(%{"xpath" => xpath} = m) do
    %{xpath: xpath, confidence: Map.get(m, "confidence")}
  end

  defp decode_clean(%{"cleaned_text" => text} = m) do
    %{cleaned_text: text, confidence: Map.get(m, "confidence")}
  end

  defp maybe_enqueue(_stage, _item_id, %{confidence: nil}, _version), do: :ok

  defp maybe_enqueue(stage, item_id, %{confidence: conf}, version) do
    threshold = Application.fetch_env!(:alambic, :review_confidence_threshold)

    if conf < threshold do
      ReviewQueue.enqueue(%{
        item_id: item_id,
        stage: stage,
        confidence: conf,
        model_version: version
      })
    end

    :ok
  end

  defp write_temp_input(content) do
    path = Path.join(System.tmp_dir!(), "alambic_input_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    path
  end
end
