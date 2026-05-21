defmodule Alambic.Cleanings do
  alias Alambic.BlobStore
  alias Alambic.Cleanings.Cleaning
  alias Alambic.Repo

  def get(item_id), do: Repo.get(Cleaning, item_id)

  def list_all, do: Repo.all(Cleaning)

  @doc """
  Stores `text` (markdown from Cham) in the blob store and upserts a cleaning row.
  `attrs` carries `:item_id`, `:discard_ranges` (list of `[start, stop]`), and optionally
  `:model_version` / `:confirmed_at`.
  """
  def save_with_text(attrs, text) when is_binary(text) do
    {:ok, sha} = BlobStore.put(text)
    item_id = Map.get(attrs, :item_id) || Map.get(attrs, "item_id")
    existing = item_id && Repo.get(Cleaning, item_id)

    (existing || %Cleaning{})
    |> Cleaning.changeset(Map.put(attrs, :content_sha256, sha))
    |> Repo.insert_or_update()
  end

  def delete(item_id) do
    case Repo.get(Cleaning, item_id) do
      nil ->
        :ok

      row ->
        {:ok, _} = Repo.delete(row)
        :ok = BlobStore.delete(row.content_sha256)
        :ok
    end
  end

  @doc """
  Applies the row's discard ranges to the given source text, returning the kept content.
  Ranges are list of `[start, stop]` half-open intervals over byte offsets.
  """
  def apply_discard_ranges(source, ranges) when is_binary(source) and is_list(ranges) do
    sorted = Enum.sort_by(ranges, fn [s, _] -> s end)

    {chunks, cursor} =
      Enum.reduce(sorted, {[], 0}, fn [start, stop], {acc, cursor} ->
        keep = binary_part(source, cursor, max(start - cursor, 0))
        {[keep | acc], stop}
      end)

    tail = binary_part(source, cursor, byte_size(source) - cursor)
    IO.iodata_to_binary([Enum.reverse(chunks), tail])
  end
end
