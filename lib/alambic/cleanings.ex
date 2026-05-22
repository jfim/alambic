defmodule Alambic.Cleanings do
  alias Alambic.BlobStore
  alias Alambic.Cleanings.Cleaning
  alias Alambic.Repo

  def get(item_id), do: Repo.get(Cleaning, item_id)

  def list_all, do: Repo.all(Cleaning)

  @doc """
  Stores `text` (markdown from Cham) in the blob store and upserts a cleaning row.

  `text` must be valid UTF-8; it is normalized to Unicode NFC before hashing
  so semantically equivalent inputs share a blob. `attrs` carries `:item_id`,
  `:discard_ranges` (list of `[start, stop]` over **codepoint** offsets of the
  normalized text), and optionally `:model_version` / `:confirmed_at`.
  """
  def save_with_text(attrs, text) when is_binary(text) do
    case :unicode.characters_to_nfc_binary(text) do
      normalized when is_binary(normalized) ->
        {:ok, sha} = BlobStore.put(normalized)
        item_id = Map.get(attrs, :item_id) || Map.get(attrs, "item_id")
        existing = item_id && Repo.get(Cleaning, item_id)

        (existing || %Cleaning{})
        |> Cleaning.changeset(Map.put(attrs, :content_sha256, sha))
        |> Repo.insert_or_update()

      {:error, _, _} ->
        {:error, :invalid_utf8}
    end
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

  Ranges are list of `[start, stop]` half-open intervals over **codepoint** offsets
  of the NFC-normalized source. `source` is assumed to already be NFC UTF-8 (as
  produced by `save_with_text/2`).
  """
  def apply_discard_ranges(source, ranges) when is_binary(source) and is_list(ranges) do
    codepoints = String.to_charlist(source)
    total = length(codepoints)
    sorted = Enum.sort_by(ranges, fn [s, _] -> s end)

    {chunks, cursor} =
      Enum.reduce(sorted, {[], 0}, fn [start, stop], {acc, cursor} ->
        keep = Enum.slice(codepoints, cursor, max(start - cursor, 0))
        {[keep | acc], stop}
      end)

    tail = Enum.slice(codepoints, cursor, total - cursor)
    List.to_string(Enum.reverse([tail | chunks]))
  end
end
