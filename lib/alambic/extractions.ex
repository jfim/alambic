defmodule Alambic.Extractions do
  alias Alambic.BlobStore
  alias Alambic.Extractions.Extraction
  alias Alambic.Repo

  def get(item_id), do: Repo.get(Extraction, item_id)

  def list_all, do: Repo.all(Extraction)

  @doc """
  Stores `html` in the blob store and upserts an extraction row referencing it.
  `attrs` carries `:item_id`, `:xpath`, and optionally `:model_version` / `:confirmed_at`.
  """
  def save_with_html(attrs, html) when is_binary(html) do
    {:ok, sha} = BlobStore.put(html)
    item_id = Map.get(attrs, :item_id) || Map.get(attrs, "item_id")
    existing = item_id && Repo.get(Extraction, item_id)

    (existing || %Extraction{})
    |> Extraction.changeset(Map.put(attrs, :content_sha256, sha))
    |> Repo.insert_or_update()
  end

  @doc """
  Deletes the row and its blob (best-effort).
  """
  def delete(item_id) do
    case Repo.get(Extraction, item_id) do
      nil ->
        :ok

      row ->
        {:ok, _} = Repo.delete(row)
        :ok = BlobStore.delete(row.content_sha256)
        :ok
    end
  end
end
