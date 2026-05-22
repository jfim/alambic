defmodule Alambic.Cleanings do
  @moduledoc """
  Cleaning revisions context.

  Each `save_revision/4` produces a new row in `cleaning_revisions` unless the
  `(content_sha256, discard_ranges)` pair matches the latest stored revision for
  the same `item_id`, in which case it returns `:unchanged`.

  Text input is NFC-normalized before hashing and storage, so semantically
  equivalent inputs share a blob and a sha.
  """

  alias Alambic.BlobStore
  alias Alambic.Cleanings.Revision
  alias Alambic.Repo

  import Ecto.Query

  @doc """
  Returns the latest revision for an item, or `nil` if none exist.
  """
  def latest(item_id) do
    from(r in Revision,
      where: r.item_id == ^item_id,
      order_by: [desc: r.revision_id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Returns all revisions for an item, ascending by `revision_id`.
  """
  def history(item_id) do
    from(r in Revision,
      where: r.item_id == ^item_id,
      order_by: [asc: r.revision_id]
    )
    |> Repo.all()
  end

  @doc """
  Returns the most recently created revision whose `content_sha256` matches
  the given hash, or `nil` if none exists. Searches across all items — used
  by inference to apply existing labels to duplicate content under a new
  `item_id` without invoking the model.
  """
  def find_latest_by_content_sha(sha) when is_binary(sha) do
    from(r in Revision,
      where: r.content_sha256 == ^sha,
      order_by: [desc: r.created_at, desc: r.revision_id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  NFC-normalizes `text`, then looks up `find_latest_by_content_sha/1` against
  its hash. Returns `nil` for invalid UTF-8 or when nothing matches.
  """
  def find_latest_by_text(text) when is_binary(text) do
    case :unicode.characters_to_nfc_binary(text) do
      normalized when is_binary(normalized) ->
        sha = :crypto.hash(:sha256, normalized) |> Base.encode16(case: :lower)
        find_latest_by_content_sha(sha)

      {:error, _, _} ->
        nil
    end
  end

  @doc """
  Returns all *latest* revisions across items (one row per item). Used by the
  dataset export.
  """
  def list_latest do
    sub =
      from(r in Revision,
        select: %{item_id: r.item_id, max_rev: max(r.revision_id)},
        group_by: r.item_id
      )

    from(r in Revision,
      join: l in subquery(sub),
      on: l.item_id == r.item_id and l.max_rev == r.revision_id
    )
    |> Repo.all()
  end

  @doc """
  NFC-normalizes `text`, stores it in the blob store, and inserts a new
  revision row unless it would be a no-op duplicate of the latest revision.

  `opts` may carry `:model_version` and `:created_at`.

  Returns `{:ok, %Revision{}, :inserted | :unchanged}` on success or
  `{:error, :invalid_utf8}` if the text is not valid UTF-8.
  """
  def save_revision(item_id, text, discard_ranges, opts \\ [])
      when is_binary(item_id) and is_binary(text) and is_list(discard_ranges) do
    case :unicode.characters_to_nfc_binary(text) do
      normalized when is_binary(normalized) ->
        {:ok, sha} = BlobStore.put(normalized)
        do_save(item_id, sha, discard_ranges, opts)

      {:error, _, _} ->
        {:error, :invalid_utf8}
    end
  end

  defp do_save(item_id, sha, ranges, opts) do
    case latest(item_id) do
      %Revision{content_sha256: ^sha, discard_ranges: ^ranges} = current ->
        {:ok, current, :unchanged}

      latest_rev ->
        next_id = (latest_rev && latest_rev.revision_id + 1) || 1

        attrs =
          %{
            item_id: item_id,
            revision_id: next_id,
            content_sha256: sha,
            discard_ranges: ranges
          }
          |> maybe_put(opts, :model_version)
          |> maybe_put(opts, :created_at)

        %Revision{}
        |> Revision.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, row} -> {:ok, row, :inserted}
          {:error, _} = err -> err
        end
    end
  end

  defp maybe_put(map, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, v} -> Map.put(map, key, v)
      :error -> map
    end
  end

  @doc """
  Deletes every revision row for `item_id` and best-effort deletes their blobs.
  """
  def delete_all(item_id) do
    rows = history(item_id)
    {_n, _} = Repo.delete_all(from r in Revision, where: r.item_id == ^item_id)

    Enum.each(rows, fn r -> BlobStore.delete(r.content_sha256) end)
    :ok
  end

  @doc """
  Applies the discard ranges to `source` text, returning the kept content.

  Ranges are list of `[start, stop]` half-open intervals over **codepoint**
  offsets of the NFC-normalized source.
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
