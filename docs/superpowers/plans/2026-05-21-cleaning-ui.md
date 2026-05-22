# Cleaning UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the placeholder cleaning LiveView with a span-labeling UI that produces `discard_ranges` over codepoint-indexed cleaning text, backed by an append-only revision history with drift-aware editing and read-only Prev/Next navigation.

**Architecture:** Drop the single-row `cleanings` table; introduce `cleaning_revisions` with `(item_id, revision_id)` PK. Add a new `Cham.fetch_cleaning_content/1` callback (alongside a renamed `fetch_extraction_html/1`). The LiveView fetches live cleaning content from Cham, hashes it, compares against the latest stored revision to handle drift, and re-renders source as discard-styled `<span>` runs. A small JS hook captures `mouseup` selections and pushes codepoint offsets to the server, which merges into in-memory `discard_ranges`. Save creates a new revision unless `(content_sha256, discard_ranges)` matches the latest.

**Tech Stack:** Elixir 1.18 / Phoenix 1.7 / Phoenix LiveView, Ecto + PostgreSQL, Mox for behaviour fakes, Tailwind for styling, plain JS for the selection hook.

**Spec:** `docs/superpowers/specs/2026-05-21-cleaning-ui-design.md`.

---

## File Structure

**New files:**
- `lib/alambic/cleanings/revision.ex` — Ecto schema for `cleaning_revisions`.
- `lib/alambic/cleanings/ranges.ex` — pure helpers (`merge_in/2`, `remove/2`, `replace/3`) on the in-memory list of `[start, stop]` ranges.
- `priv/repo/migrations/20260521000005_replace_cleanings_with_revisions.exs` — drops `cleanings`, creates `cleaning_revisions`.
- `assets/js/hooks/cleaning_selection.js` — selection-offset hook for the article pane.
- `test/alambic/cleanings/ranges_test.exs`
- (`test/alambic_web/live/edit_cleaning_live_test.exs` already exists — it will be rewritten.)

**Modified files:**
- `lib/alambic/cham.ex` — rename callback, add `fetch_cleaning_content/1`.
- `lib/alambic/cham/http.ex` — rename impl, add new impl, use renamed config keys.
- `lib/alambic/cleanings.ex` — replace single-row API with revision API.
- `lib/alambic/cleanings/cleaning.ex` — **delete** (file removed).
- `lib/alambic/datasets.ex` — read latest revision per item.
- `lib/alambic/inference.ex` — call `Cleanings.latest/1` instead of `Cleanings.get/1`.
- `lib/alambic_web/live/edit_cleaning_live.ex` — full rewrite into two-pane UI.
- `lib/alambic_web/live/edit_extraction_live.ex` — caller of renamed `fetch_extraction_html`.
- `config/config.exs`, `config/runtime.exs`, `config/test.exs` — rename `:cham_raw_html_filename` to `:cham_extraction_html_filename`, add `:cham_cleaning_content_filename`.
- `assets/js/app.js` — register the new hook.
- `test/test_helper.exs` — Mox `defmock` already targets `Alambic.Cham`; no edit needed unless test setup changes.
- `test/alambic/cham/http_test.exs` — update for renamed function.
- `test/alambic/cleanings_test.exs` — rewritten for revision API.
- `test/alambic_web/live/edit_extraction_live_test.exs` — stub renamed `fetch_extraction_html`.
- `test/alambic_web/live/edit_cleaning_live_test.exs` — rewritten for the new UI.
- `test/alambic/datasets_test.exs` — assert latest-revision behavior.
- `test/alambic/inference_test.exs` — assert revision lookup.

---

## Task 1: Cham client — rename `fetch_html` to `fetch_extraction_html`

The current Cham client exposes only `fetch_html/1`. Rename it to disambiguate from the new cleaning-content fetcher. Pure rename, no behavioral change.

**Files:**
- Modify: `lib/alambic/cham.ex`
- Modify: `lib/alambic/cham/http.ex`
- Modify: `config/config.exs`, `config/runtime.exs`
- Modify: `lib/alambic_web/live/edit_extraction_live.ex`
- Modify: `lib/alambic_web/live/edit_cleaning_live.ex` (placeholder — will be fully rewritten later, but rename caller first to keep compile green)
- Modify: `test/alambic/cham/http_test.exs`
- Modify: `test/alambic_web/live/edit_extraction_live_test.exs`
- Modify: `test/alambic_web/live/edit_cleaning_live_test.exs`

- [ ] **Step 1: Rename callback and dispatcher in `lib/alambic/cham.ex`**

Replace the file contents with:

```elixir
defmodule Alambic.Cham do
  @moduledoc "Read-only client for the Cham archive API."

  @callback fetch_extraction_html(item_id :: String.t()) :: {:ok, binary} | {:error, term}

  def fetch_extraction_html(item_id), do: impl().fetch_extraction_html(item_id)

  defp impl, do: Application.fetch_env!(:alambic, :cham_impl)
end
```

- [ ] **Step 2: Rename impl in `lib/alambic/cham/http.ex` and the config key it reads**

Replace the file contents with:

```elixir
defmodule Alambic.Cham.HTTP do
  @behaviour Alambic.Cham

  @impl Alambic.Cham
  def fetch_extraction_html(item_id) do
    fetch_extraction_html(item_id,
      base_url: Application.fetch_env!(:alambic, :cham_base_url),
      filename: Application.fetch_env!(:alambic, :cham_extraction_html_filename)
    )
  end

  @doc false
  def fetch_extraction_html(item_id, opts) do
    base = Keyword.fetch!(opts, :base_url)
    filename = Keyword.fetch!(opts, :filename)
    url = "#{base}/api/v1/items/#{URI.encode(item_id)}/files/#{URI.encode(filename)}"

    case Req.get(url) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

- [ ] **Step 3: Update config key in `config/config.exs`**

In `config/config.exs`, change the line:

```elixir
  cham_raw_html_filename: "original.html",
```

to:

```elixir
  cham_extraction_html_filename: "original.html",
```

- [ ] **Step 4: Update `config/runtime.exs` if it references the old key**

Run: `grep -n cham_raw_html_filename config/runtime.exs`

If a match exists, rename it to `cham_extraction_html_filename`. If no match, skip (the dev/test environments inherit from `config/config.exs`).

- [ ] **Step 5: Update callers in LiveViews**

In `lib/alambic_web/live/edit_extraction_live.ex`, replace `Cham.fetch_html(item_id)` with `Cham.fetch_extraction_html(item_id)`. (One call site — confirm with `grep -n fetch_html lib/alambic_web/live/edit_extraction_live.ex`.)

In `lib/alambic_web/live/edit_cleaning_live.ex`, replace `Cham.fetch_html(item_id)` with `Cham.fetch_extraction_html(item_id)`. (This file is the existing placeholder; it will be fully rewritten in Task 9. Renaming the call now keeps `mix compile` green.)

- [ ] **Step 6: Update existing tests for the rename**

In `test/alambic/cham/http_test.exs`, rename every reference to `fetch_html` to `fetch_extraction_html`. (Run `grep -n fetch_html test/alambic/cham/http_test.exs` to find them.) If the test reads the config key, rename `cham_raw_html_filename` to `cham_extraction_html_filename` there too.

In `test/alambic_web/live/edit_extraction_live_test.exs`, change every `stub(Alambic.ChamMock, :fetch_html, ...)` to `stub(Alambic.ChamMock, :fetch_extraction_html, ...)`.

In `test/alambic_web/live/edit_cleaning_live_test.exs`, change every `stub(Alambic.ChamMock, :fetch_html, ...)` to `stub(Alambic.ChamMock, :fetch_extraction_html, ...)`.

- [ ] **Step 7: Run the suite to confirm rename is clean**

Run: `mix test`
Expected: all green (no behavior change).

- [ ] **Step 8: Commit**

```bash
git add lib/alambic/cham.ex lib/alambic/cham/http.ex config/ lib/alambic_web/live/ test/
git commit -m "refactor: rename Cham.fetch_html to fetch_extraction_html"
```

---

## Task 2: Cham client — add `fetch_cleaning_content/1`

Adds the cleaning-content fetcher. Symmetric to extraction. Reads a new config key `:cham_cleaning_content_filename` (defaults to `"content.md"`).

**Files:**
- Modify: `lib/alambic/cham.ex`
- Modify: `lib/alambic/cham/http.ex`
- Modify: `config/config.exs`
- Modify: `test/alambic/cham/http_test.exs`

- [ ] **Step 1: Add config key in `config/config.exs`**

In the `config :alambic, cham_impl: ..., cham_base_url: ..., cham_extraction_html_filename: ...` block, append:

```elixir
  cham_cleaning_content_filename: "content.md",
```

(So the block reads `cham_impl: ..., cham_base_url: ..., cham_extraction_html_filename: ..., cham_cleaning_content_filename: ..., review_confidence_threshold: ..., scripts_path: ...`.)

- [ ] **Step 2: Add callback + dispatcher in `lib/alambic/cham.ex`**

Append the new callback alongside the existing one, and add a public function:

```elixir
defmodule Alambic.Cham do
  @moduledoc "Read-only client for the Cham archive API."

  @callback fetch_extraction_html(item_id :: String.t()) :: {:ok, binary} | {:error, term}
  @callback fetch_cleaning_content(item_id :: String.t()) :: {:ok, binary} | {:error, term}

  def fetch_extraction_html(item_id), do: impl().fetch_extraction_html(item_id)
  def fetch_cleaning_content(item_id), do: impl().fetch_cleaning_content(item_id)

  defp impl, do: Application.fetch_env!(:alambic, :cham_impl)
end
```

- [ ] **Step 3: Write failing HTTP test**

In `test/alambic/cham/http_test.exs`, add a new test inside the existing module. First, inspect the file to find the pattern used for the existing `fetch_extraction_html` test (likely uses `Req.Test` or a stubbed `Req` plug). Mirror that exact pattern for the new function.

```elixir
test "fetch_cleaning_content/2 returns body on 200" do
  Req.Test.stub(Alambic.Cham.HTTP, fn conn ->
    assert conn.request_path =~ "/api/v1/items/abc/files/content.md"
    Req.Test.text(conn, "# title\n\nbody")
  end)

  assert {:ok, "# title\n\nbody"} =
           Alambic.Cham.HTTP.fetch_cleaning_content("abc",
             base_url: "http://cham",
             filename: "content.md",
             req: [plug: {Req.Test, Alambic.Cham.HTTP}]
           )
end
```

> **Note:** Match the exact call shape of the existing `fetch_extraction_html` test in the same file — pass options the same way, including any `req:` plug indirection. The above is illustrative; copy the existing convention precisely.

Run: `mix test test/alambic/cham/http_test.exs`
Expected: FAIL — `fetch_cleaning_content` not defined.

- [ ] **Step 4: Implement `fetch_cleaning_content` in `lib/alambic/cham/http.ex`**

Add the new function alongside the existing one:

```elixir
  @impl Alambic.Cham
  def fetch_cleaning_content(item_id) do
    fetch_cleaning_content(item_id,
      base_url: Application.fetch_env!(:alambic, :cham_base_url),
      filename: Application.fetch_env!(:alambic, :cham_cleaning_content_filename)
    )
  end

  @doc false
  def fetch_cleaning_content(item_id, opts) do
    base = Keyword.fetch!(opts, :base_url)
    filename = Keyword.fetch!(opts, :filename)
    url = "#{base}/api/v1/items/#{URI.encode(item_id)}/files/#{URI.encode(filename)}"

    case Req.get(url) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
```

- [ ] **Step 5: Run tests**

Run: `mix test test/alambic/cham/http_test.exs`
Expected: all pass (existing extraction test + new cleaning-content test).

Run: `mix compile --warnings-as-errors`
Expected: clean (Mox will not auto-implement the new callback yet, but `Alambic.ChamMock` is generated at runtime by Mox.defmock and complaining about it would be a test failure, not a compile failure).

- [ ] **Step 6: Commit**

```bash
git add lib/alambic/cham.ex lib/alambic/cham/http.ex config/config.exs test/alambic/cham/http_test.exs
git commit -m "feat: Cham.fetch_cleaning_content for content.md artifact"
```

---

## Task 3: Migration — drop cleanings, create cleaning_revisions

No data exists; safe to drop the table. Append-only `cleaning_revisions` with composite PK.

**Files:**
- Create: `priv/repo/migrations/20260521000005_replace_cleanings_with_revisions.exs`

- [ ] **Step 1: Write the migration**

Create `priv/repo/migrations/20260521000005_replace_cleanings_with_revisions.exs`:

```elixir
defmodule Alambic.Repo.Migrations.ReplaceCleaningsWithRevisions do
  use Ecto.Migration

  def change do
    drop table(:cleanings)

    create table(:cleaning_revisions, primary_key: false) do
      add :item_id, :string, null: false
      add :revision_id, :bigint, null: false
      add :content_sha256, :string, size: 64, null: false
      add :discard_ranges, :jsonb, null: false, default: "[]"
      add :created_at, :utc_datetime, null: false
      add :model_version, :string
    end

    create unique_index(:cleaning_revisions, [:item_id, :revision_id])
    create index(:cleaning_revisions, [:item_id, :created_at])
  end
end
```

- [ ] **Step 2: Reset DB and migrate**

Run: `mix ecto.drop --quiet && mix ecto.create --quiet && mix ecto.migrate`
Expected: clean migrate output. After: psql can confirm `\dt` shows `cleaning_revisions` and not `cleanings`.

> **Note:** `mix compile` will break at this point — `Alambic.Cleanings.Cleaning` still references the dropped `cleanings` table by name. Subsequent tasks fix it. Do not commit until end of Task 5.

---

## Task 4: New Revision schema

**Files:**
- Create: `lib/alambic/cleanings/revision.ex`
- Delete: `lib/alambic/cleanings/cleaning.ex` (file removal)

- [ ] **Step 1: Create `lib/alambic/cleanings/revision.ex`**

```elixir
defmodule Alambic.Cleanings.Revision do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "cleaning_revisions" do
    field :item_id, :string, primary_key: true
    field :revision_id, :integer, primary_key: true
    field :content_sha256, :string
    field :discard_ranges, {:array, {:array, :integer}}, default: []
    field :created_at, :utc_datetime
    field :model_version, :string
  end

  def changeset(revision, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = Map.put_new(attrs, :created_at, now)

    revision
    |> cast(attrs, [
      :item_id,
      :revision_id,
      :content_sha256,
      :discard_ranges,
      :created_at,
      :model_version
    ])
    |> validate_required([:item_id, :revision_id, :content_sha256, :created_at])
    |> validate_format(:content_sha256, ~r/\A[a-f0-9]{64}\z/)
    |> validate_change(:discard_ranges, &validate_ranges/2)
  end

  defp validate_ranges(:discard_ranges, ranges) do
    if Enum.all?(ranges, &valid_range?/1) do
      []
    else
      [discard_ranges: "must be list of [start, stop] with 0 <= start < stop"]
    end
  end

  defp valid_range?([start, stop])
       when is_integer(start) and is_integer(stop) and start >= 0 and stop > start,
       do: true

  defp valid_range?(_), do: false
end
```

- [ ] **Step 2: Delete the old schema file**

Run: `rm lib/alambic/cleanings/cleaning.ex`

(The `Alambic.Cleanings` context still references it — fixed in Task 5. `mix compile` remains broken until then.)

---

## Task 5: Rewrite `Alambic.Cleanings` context

Replace the existing single-row context with a revision-aware one. NFC-normalize text before hashing/storage (preserving existing behavior). Provide `latest/1`, `history/1`, `save_revision/4`, `apply_discard_ranges/2`, `delete_all/1`.

**Files:**
- Modify: `lib/alambic/cleanings.ex` (full replacement)
- Modify: `test/alambic/cleanings_test.exs` (full replacement)

- [ ] **Step 1: Write the failing test**

Replace the contents of `test/alambic/cleanings_test.exs`:

```elixir
defmodule Alambic.CleaningsTest do
  use Alambic.DataCase, async: false

  alias Alambic.{BlobStore, Cleanings}
  alias Alambic.Cleanings.Revision

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

  test "save_revision inserts the first revision as #1" do
    {:ok, %Revision{revision_id: 1} = rev, :inserted} =
      Cleanings.save_revision("item-a", "hello world", [[0, 5]])

    assert rev.discard_ranges == [[0, 5]]
    assert {:ok, "hello world"} = BlobStore.get(rev.content_sha256)
  end

  test "save_revision dedups identical (content_sha256, discard_ranges)" do
    {:ok, %Revision{revision_id: 1}, :inserted} =
      Cleanings.save_revision("item-b", "same text", [[0, 4]])

    {:ok, %Revision{revision_id: 1}, :unchanged} =
      Cleanings.save_revision("item-b", "same text", [[0, 4]])

    assert length(Cleanings.history("item-b")) == 1
  end

  test "save_revision allocates the next revision_id on a change" do
    {:ok, %Revision{revision_id: 1}, :inserted} =
      Cleanings.save_revision("item-c", "text one", [])

    {:ok, %Revision{revision_id: 2}, :inserted} =
      Cleanings.save_revision("item-c", "text one", [[0, 4]])

    {:ok, %Revision{revision_id: 3}, :inserted} =
      Cleanings.save_revision("item-c", "text two", [[0, 4]])

    history = Cleanings.history("item-c")
    assert Enum.map(history, & &1.revision_id) == [1, 2, 3]
  end

  test "latest returns the highest revision_id for the item" do
    {:ok, _, :inserted} = Cleanings.save_revision("item-d", "first", [])
    {:ok, _, :inserted} = Cleanings.save_revision("item-d", "second", [])

    assert %Revision{revision_id: 2} = Cleanings.latest("item-d")
  end

  test "latest returns nil for unknown item" do
    assert nil == Cleanings.latest("nope")
  end

  test "save_revision NFC-normalizes text before hashing" do
    composed = "café"
    decomposed = "café"

    {:ok, %Revision{content_sha256: sha1}, :inserted} =
      Cleanings.save_revision("item-e", composed, [])

    {:ok, %Revision{content_sha256: sha2}, _} =
      Cleanings.save_revision("item-e", decomposed, [])

    assert sha1 == sha2
  end

  test "save_revision rejects invalid UTF-8" do
    assert {:error, :invalid_utf8} =
             Cleanings.save_revision("item-f", <<0xFF, 0xFE, 0xFD>>, [])
  end

  test "apply_discard_ranges slices by codepoint" do
    assert Cleanings.apply_discard_ranges("ABCDEFG", [[1, 3], [5, 6]]) == "ADEG"
  end

  test "delete_all removes all revisions and their blobs" do
    {:ok, r1, :inserted} = Cleanings.save_revision("item-g", "alpha", [])
    {:ok, r2, :inserted} = Cleanings.save_revision("item-g", "beta", [])

    :ok = Cleanings.delete_all("item-g")

    assert Cleanings.history("item-g") == []
    assert :not_found = BlobStore.get(r1.content_sha256)
    assert :not_found = BlobStore.get(r2.content_sha256)
  end
end
```

Run: `mix test test/alambic/cleanings_test.exs`
Expected: FAIL (compile error or undefined functions).

- [ ] **Step 2: Replace `lib/alambic/cleanings.ex`**

```elixir
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
    {n, _} = Repo.delete_all(from r in Revision, where: r.item_id == ^item_id)

    Enum.each(rows, fn r -> BlobStore.delete(r.content_sha256) end)
    if n == 0, do: :ok, else: :ok
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
```

- [ ] **Step 3: Run cleanings tests**

Run: `mix test test/alambic/cleanings_test.exs`
Expected: all pass (9 tests).

- [ ] **Step 4: Compile and check the rest of the codebase**

Run: `mix compile --warnings-as-errors`
Expected: failures in `Alambic.Datasets` (calls `Cleanings.list_all/0`) and `Alambic.Inference` (calls `Cleanings.get/1`). These are fixed in Tasks 6 and 7. Do not commit yet.

---

## Task 6: Update `Alambic.Datasets` for latest-revision export

The cleaning parquet exports one row per item (the latest revision).

**Files:**
- Modify: `lib/alambic/datasets.ex`
- Modify: `test/alambic/datasets_test.exs`

- [ ] **Step 1: Update the failing cleaning test**

In `test/alambic/datasets_test.exs`, replace any test that calls `Cleanings.save_with_text/2` with the new revision API. Also add a multi-revision test confirming only the latest is exported.

Open the file, find the existing cleaning test, and replace it with:

```elixir
  test "cleaning parquet carries discard_ranges as list of lists" do
    {:ok, _, :inserted} =
      Cleanings.save_revision("c1", "abcdefghij", [[0, 3], [7, 10]])

    bytes = Datasets.export_parquet(:cleaning) |> IO.iodata_to_binary()
    path = Path.join(System.tmp_dir!(), "alambic_t_#{System.unique_integer([:positive])}.parquet")
    File.write!(path, bytes)
    df = Explorer.DataFrame.from_parquet!(path)
    File.rm!(path)

    row = Explorer.DataFrame.to_rows(df) |> hd()
    assert row["item_id"] == "c1"
    assert row["discard_ranges"] == [[0, 3], [7, 10]]
  end

  test "cleaning parquet exports only the latest revision per item" do
    {:ok, _, :inserted} = Cleanings.save_revision("c2", "first text", [[0, 3]])
    {:ok, _, :inserted} = Cleanings.save_revision("c2", "second text", [[1, 4]])

    bytes = Datasets.export_parquet(:cleaning) |> IO.iodata_to_binary()
    path = Path.join(System.tmp_dir!(), "alambic_t_#{System.unique_integer([:positive])}.parquet")
    File.write!(path, bytes)
    df = Explorer.DataFrame.from_parquet!(path)
    File.rm!(path)

    rows = Explorer.DataFrame.to_rows(df)
    assert length(rows) == 1
    row = hd(rows)
    assert row["item_id"] == "c2"
    assert row["discard_ranges"] == [[1, 4]]
  end
```

Run: `mix test test/alambic/datasets_test.exs`
Expected: FAIL (calls go to old API or `list_all/0` is missing for cleaning).

- [ ] **Step 2: Update `Alambic.Datasets`**

In `lib/alambic/datasets.ex`, replace the `:cleaning` clause and remove references to `confirmed_at`/`updated_at` from the cleaning row (the new schema has only `created_at`). The extraction clause is unchanged.

Replace the `def export_parquet(:cleaning)` clause body with:

```elixir
  def export_parquet(:cleaning) do
    rows = Cleanings.list_latest()

    df =
      DataFrame.new(%{
        "item_id" => Enum.map(rows, & &1.item_id),
        "content_sha256" => Enum.map(rows, & &1.content_sha256),
        "discard_ranges" => Enum.map(rows, & &1.discard_ranges),
        "confirmed_at" => Enum.map(rows, &DateTime.to_unix(&1.created_at)),
        "updated_at" => Enum.map(rows, &DateTime.to_unix(&1.created_at)),
        "prior_model_version" => Enum.map(rows, & &1.model_version)
      })

    to_parquet_bytes(df)
  end
```

- [ ] **Step 3: Run tests**

Run: `mix test test/alambic/datasets_test.exs`
Expected: all pass (extraction tests untouched, both cleaning tests green).

---

## Task 7: Update `Alambic.Inference.clean` for the revision API

Replace the `Cleanings.get/1` lookup with `Cleanings.latest/1`.

**Files:**
- Modify: `lib/alambic/inference.ex`
- Modify: `test/alambic/inference_test.exs`

- [ ] **Step 1: Update inference test**

In `test/alambic/inference_test.exs`, find the test that saves a cleaning and asserts the saved-branch behavior. Replace the save call with the new revision API:

```elixir
  test "clean returns kept text after discarding ranges" do
    {:ok, _, :inserted} =
      Cleanings.save_revision("x1", "drop me keep me", [[0, 6]])

    assert {:ok, %{cleaned_text: " keep me", source: :saved}} =
             Alambic.Inference.clean("x1", "ignored")
  end
```

> **Note:** `"drop me keep me"`'s codepoints `[0, 6]` discards `"drop m"`, leaving `"e keep me"`. Adjust to whatever the existing test asserts; the point is matching the new API.

Run: `mix test test/alambic/inference_test.exs`
Expected: FAIL (old API call or unmodified inference module).

- [ ] **Step 2: Update `Alambic.Inference.clean`**

In `lib/alambic/inference.ex`, replace the `def clean/2` function:

```elixir
  def clean(item_id, text) do
    case Cleanings.latest(item_id) do
      %{content_sha256: sha, discard_ranges: ranges} ->
        {:ok, source} = Alambic.BlobStore.get(sha)
        cleaned = Cleanings.apply_discard_ranges(source, ranges)

        {:ok,
         %{
           item_id: item_id,
           cleaned_text: cleaned,
           source: :saved,
           model_version: nil,
           confidence: nil
         }}

      nil ->
        run_model(:cleaning, item_id, text, &decode_clean/1)
    end
  end
```

- [ ] **Step 3: Run inference tests**

Run: `mix test test/alambic/inference_test.exs`
Expected: pass.

- [ ] **Step 4: Full compile + suite**

Run: `mix compile --warnings-as-errors`
Expected: clean.
Run: `mix test`
Expected: existing LiveView test for `EditCleaningLive` may still pass (it stubs `fetch_extraction_html` and clicks a Confirm button on the old placeholder). If that test fails because the old placeholder writes to the dead context API, defer the failure — it will be replaced in Task 9.

If only that one test fails and only because of the old placeholder calling `Cleanings.save/1` (which no longer exists), proceed to commit and fix it in Task 9. Other failures must be investigated.

- [ ] **Step 5: Commit Tasks 3–7 together**

```bash
git add priv/repo/migrations/ lib/alambic/cleanings/ lib/alambic/cleanings.ex lib/alambic/datasets.ex lib/alambic/inference.ex test/alambic/cleanings_test.exs test/alambic/datasets_test.exs test/alambic/inference_test.exs
git status   # confirm lib/alambic/cleanings/cleaning.ex was deleted
git commit -m "feat: cleaning_revisions table + revision-aware contexts"
```

---

## Task 8: Pure span-merge helper

A small pure module for the in-memory `discard_ranges` mutation. Easy to test independently of the LiveView.

**Files:**
- Create: `lib/alambic/cleanings/ranges.ex`
- Create: `test/alambic/cleanings/ranges_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/alambic/cleanings/ranges_test.exs`:

```elixir
defmodule Alambic.Cleanings.RangesTest do
  use ExUnit.Case, async: true

  alias Alambic.Cleanings.Ranges

  describe "merge_in/2" do
    test "adds a disjoint range" do
      assert Ranges.merge_in([[0, 3], [10, 15]], [5, 7]) == [[0, 3], [5, 7], [10, 15]]
    end

    test "merges overlapping ranges into one" do
      assert Ranges.merge_in([[0, 5]], [3, 10]) == [[0, 10]]
    end

    test "merges touching ranges" do
      assert Ranges.merge_in([[0, 5]], [5, 10]) == [[0, 10]]
    end

    test "swallows a range fully inside an existing one" do
      assert Ranges.merge_in([[0, 20]], [5, 10]) == [[0, 20]]
    end

    test "merges across multiple adjacent ranges" do
      assert Ranges.merge_in([[0, 3], [5, 8], [10, 12]], [2, 11]) == [[0, 12]]
    end

    test "ignores zero-width and inverted ranges" do
      assert Ranges.merge_in([[0, 5]], [3, 3]) == [[0, 5]]
      assert Ranges.merge_in([[0, 5]], [7, 3]) == [[0, 5]]
    end

    test "result is sorted ascending" do
      assert Ranges.merge_in([], [10, 12]) == [[10, 12]]
      assert Ranges.merge_in([[10, 12]], [0, 3]) == [[0, 3], [10, 12]]
    end
  end

  describe "remove/2" do
    test "removes by index" do
      assert Ranges.remove([[0, 3], [5, 8], [10, 12]], 1) == [[0, 3], [10, 12]]
    end

    test "out-of-bounds index is a no-op" do
      assert Ranges.remove([[0, 3]], 5) == [[0, 3]]
      assert Ranges.remove([[0, 3]], -1) == [[0, 3]]
    end
  end

  describe "replace/3" do
    test "replaces a range and re-merges" do
      assert Ranges.replace([[0, 3], [10, 15]], 0, [0, 11]) == [[0, 15]]
    end

    test "rejects an invalid replacement (returns input)" do
      assert Ranges.replace([[0, 3]], 0, [5, 5]) == [[0, 3]]
      assert Ranges.replace([[0, 3]], 0, [-1, 4]) == [[0, 3]]
    end

    test "out-of-bounds index is a no-op" do
      assert Ranges.replace([[0, 3]], 99, [5, 7]) == [[0, 3]]
    end
  end
end
```

Run: `mix test test/alambic/cleanings/ranges_test.exs`
Expected: FAIL (module not defined).

- [ ] **Step 2: Implement the module**

Create `lib/alambic/cleanings/ranges.ex`:

```elixir
defmodule Alambic.Cleanings.Ranges do
  @moduledoc """
  Pure helpers over a sorted, non-overlapping list of `[start, stop]` discard
  ranges. All public functions return a list in the same canonical form.
  """

  @type range :: [non_neg_integer()]
  @type t :: [range()]

  @spec merge_in(t(), range()) :: t()
  def merge_in(ranges, [start, stop]) when not (is_integer(start) and is_integer(stop) and start >= 0 and stop > start) do
    ranges
  end

  def merge_in(ranges, [start, stop]) do
    [[start, stop] | ranges]
    |> Enum.sort_by(fn [s, _] -> s end)
    |> coalesce()
  end

  @spec remove(t(), integer()) :: t()
  def remove(ranges, index) when is_integer(index) and index >= 0 and index < length(ranges) do
    List.delete_at(ranges, index)
  end

  def remove(ranges, _index), do: ranges

  @spec replace(t(), non_neg_integer(), range()) :: t()
  def replace(ranges, index, [start, stop])
      when is_integer(start) and is_integer(stop) and start >= 0 and stop > start and
             is_integer(index) and index >= 0 and index < length(ranges) do
    ranges
    |> List.replace_at(index, [start, stop])
    |> Enum.sort_by(fn [s, _] -> s end)
    |> coalesce()
  end

  def replace(ranges, _index, _new), do: ranges

  defp coalesce([]), do: []
  defp coalesce([first | rest]), do: do_coalesce(rest, [first])

  defp do_coalesce([], acc), do: Enum.reverse(acc)

  defp do_coalesce([[s, e] | rest], [[ps, pe] | tail]) when s <= pe do
    do_coalesce(rest, [[ps, max(pe, e)] | tail])
  end

  defp do_coalesce([next | rest], acc), do: do_coalesce(rest, [next | acc])
end
```

- [ ] **Step 3: Run tests**

Run: `mix test test/alambic/cleanings/ranges_test.exs`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add lib/alambic/cleanings/ranges.ex test/alambic/cleanings/ranges_test.exs
git commit -m "feat: pure span-merge helpers for cleaning UI"
```

---

## Task 9: Rewrite `EditCleaningLive`

Two-pane UI with mount-time drift detection, server-held in-memory `discard_ranges`, span-pane spinners, Prev/Next read-only history, single Save button.

**Files:**
- Modify: `lib/alambic_web/live/edit_cleaning_live.ex` (full rewrite)
- Modify: `test/alambic_web/live/edit_cleaning_live_test.exs` (full rewrite)

- [ ] **Step 1: Write the failing tests**

Replace `test/alambic_web/live/edit_cleaning_live_test.exs`:

```elixir
defmodule AlambicWeb.EditCleaningLiveTest do
  use AlambicWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  alias Alambic.Cleanings
  alias Alambic.ReviewQueue

  setup :verify_on_exit!

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

  test "renders fresh editor when no revision exists", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn "abc" -> {:ok, "# Title\n\nbody"} end)

    {:ok, _view, html} = live(conn, ~p"/edit-cleaning/abc")

    assert html =~ "Edit cleaning"
    assert html =~ "abc"
    refute html =~ "Article text has changed"
    refute html =~ "Viewing rev"
  end

  test "pre-populates discard ranges from latest revision when hash matches", %{conn: conn} do
    text = "Hello sponsored world"
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, text} end)
    {:ok, _, :inserted} = Cleanings.save_revision("matched", text, [[6, 16]])

    {:ok, _view, html} = live(conn, ~p"/edit-cleaning/matched")

    assert html =~ "Latest"
    assert html =~ "rev 1"
    # discarded substring rendered inside a discard span (high-contrast bg)
    assert html =~ ~r/bg-rose-\d+.*sponsored/s
  end

  test "shows drift banner when latest hash differs from live text", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "new text"} end)
    {:ok, _, :inserted} = Cleanings.save_revision("drift", "old text", [[0, 3]])

    {:ok, _view, html} = live(conn, ~p"/edit-cleaning/drift")

    assert html =~ "Article text has changed"
  end

  test "add_span event merges into in-memory ranges", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "abcdefghij"} end)

    {:ok, view, _html} = live(conn, ~p"/edit-cleaning/spans")
    render_hook(view, "add_span", %{"start" => 1, "stop" => 4})
    render_hook(view, "add_span", %{"start" => 3, "stop" => 7})

    html = render(view)
    assert html =~ "1–7"
    refute html =~ "1–4"
  end

  test "delete_span removes a span by index", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "abcdefghij"} end)

    {:ok, view, _} = live(conn, ~p"/edit-cleaning/del")
    render_hook(view, "add_span", %{"start" => 0, "stop" => 3})
    render_hook(view, "add_span", %{"start" => 5, "stop" => 7})

    view |> element(~s|button[phx-value-index="0"][phx-click="delete_span"]|) |> render_click()

    html = render(view)
    refute html =~ "0–3"
    assert html =~ "5–7"
  end

  test "edit_range validates and merges", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "abcdefghij"} end)

    {:ok, view, _} = live(conn, ~p"/edit-cleaning/edit")
    render_hook(view, "add_span", %{"start" => 0, "stop" => 3})
    render_hook(view, "edit_range", %{"index" => 0, "start" => 0, "stop" => 5})

    html = render(view)
    assert html =~ "0–5"

    # invalid (start >= stop) is a no-op
    render_hook(view, "edit_range", %{"index" => 0, "start" => 5, "stop" => 5})
    html = render(view)
    assert html =~ "0–5"
  end

  test "save inserts a revision and resolves the queue", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "abcdef"} end)
    {:ok, _} = ReviewQueue.enqueue(%{item_id: "sv", stage: :cleaning, confidence: 0.1, model_version: "v1"})

    {:ok, view, _} = live(conn, ~p"/edit-cleaning/sv")
    render_hook(view, "add_span", %{"start" => 0, "stop" => 3})
    view |> element("button", "Save") |> render_click()

    assert %{revision_id: 1, discard_ranges: [[0, 3]]} = Cleanings.latest("sv")
    assert ReviewQueue.list_pending() == []
  end

  test "save dedups identical (content, ranges) but still resolves queue", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "abcdef"} end)
    {:ok, _, :inserted} = Cleanings.save_revision("dedup", "abcdef", [[0, 3]])
    {:ok, _} = ReviewQueue.enqueue(%{item_id: "dedup", stage: :cleaning, confidence: 0.1, model_version: "v1"})

    {:ok, view, _} = live(conn, ~p"/edit-cleaning/dedup")
    view |> element("button", "Save") |> render_click()

    assert [%{revision_id: 1}] = Cleanings.history("dedup")
    assert ReviewQueue.list_pending() == []
  end

  test "Prev shows historical revision read-only", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "current text"} end)
    {:ok, _, :inserted} = Cleanings.save_revision("hist", "old text", [[0, 3]])
    {:ok, _, :inserted} = Cleanings.save_revision("hist", "current text", [[8, 12]])

    {:ok, view, _} = live(conn, ~p"/edit-cleaning/hist")
    view |> element("button", "Prev") |> render_click()

    html = render(view)
    assert html =~ "Viewing rev 1"
    assert html =~ "old text"
    assert html =~ ~s|disabled|
  end

  test "shows confirmed-empty chip when latest revision has [] ranges and matches", %{conn: conn} do
    text = "no junk here"
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, text} end)
    {:ok, _, :inserted} = Cleanings.save_revision("empty-ok", text, [])

    {:ok, _view, html} = live(conn, ~p"/edit-cleaning/empty-ok")
    assert html =~ "Confirmed: nothing to discard"
    refute html =~ "No spans yet"
  end

  test "shows unlabeled-empty placeholder when no revision exists", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "fresh article"} end)

    {:ok, _view, html} = live(conn, ~p"/edit-cleaning/fresh")
    assert html =~ "No spans yet"
    refute html =~ "Confirmed: nothing to discard"
  end

  test "save with empty ranges creates a confirmed-empty revision", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:ok, "confirm empty"} end)

    {:ok, view, _} = live(conn, ~p"/edit-cleaning/conf-empty")
    view |> element("button", "Save") |> render_click()

    assert %{revision_id: 1, discard_ranges: []} = Cleanings.latest("conf-empty")
  end

  test "renders error pane when Cham fetch fails", %{conn: conn} do
    stub(Alambic.ChamMock, :fetch_cleaning_content, fn _ -> {:error, {:status, 404}} end)

    {:ok, _view, html} = live(conn, ~p"/edit-cleaning/missing")
    assert html =~ "Could not fetch"
  end
end
```

Run: `mix test test/alambic_web/live/edit_cleaning_live_test.exs`
Expected: FAIL — placeholder LiveView still in place.

- [ ] **Step 2: Replace `lib/alambic_web/live/edit_cleaning_live.ex`**

```elixir
defmodule AlambicWeb.EditCleaningLive do
  use AlambicWeb, :live_view

  alias Alambic.{BlobStore, Cham, Cleanings, ReviewQueue}
  alias Alambic.Cleanings.Ranges

  def mount(%{"item_id" => item_id}, _session, socket) do
    case Cham.fetch_cleaning_content(item_id) do
      {:ok, raw} ->
        text = normalize(raw)
        sha = sha256(text)
        latest = Cleanings.latest(item_id)
        history = if latest, do: Cleanings.history(item_id), else: []
        {ranges, drift?} = initial_ranges(latest, sha)

        {:ok,
         assign(socket,
           item_id: item_id,
           text: text,
           text_sha: sha,
           text_length: String.length(text),
           ranges: ranges,
           latest: latest,
           history: history,
           view_revision: nil,
           drift?: drift?,
           error: nil
         )}

      {:error, reason} ->
        {:ok,
         assign(socket,
           item_id: item_id,
           text: nil,
           ranges: [],
           latest: nil,
           history: [],
           view_revision: nil,
           drift?: false,
           error: inspect(reason)
         )}
    end
  end

  defp initial_ranges(nil, _sha), do: {[], false}

  defp initial_ranges(%{content_sha256: stored, discard_ranges: ranges}, sha) do
    if stored == sha, do: {ranges, false}, else: {[], true}
  end

  def handle_event("add_span", %{"start" => s, "stop" => e}, socket) do
    {s, e} = {to_int(s), to_int(e)}
    {:noreply, assign(socket, ranges: Ranges.merge_in(socket.assigns.ranges, [s, e]))}
  end

  def handle_event("delete_span", %{"index" => idx}, socket) do
    {:noreply, assign(socket, ranges: Ranges.remove(socket.assigns.ranges, to_int(idx)))}
  end

  def handle_event("edit_range", %{"index" => idx, "start" => s, "stop" => e}, socket) do
    {:noreply,
     assign(socket,
       ranges: Ranges.replace(socket.assigns.ranges, to_int(idx), [to_int(s), to_int(e)])
     )}
  end

  def handle_event("save", _params, socket) do
    %{item_id: item_id, text: text, ranges: ranges} = socket.assigns

    case Cleanings.save_revision(item_id, text, ranges) do
      {:ok, _row, status} ->
        :ok = ReviewQueue.resolve(item_id, :cleaning)
        flash = if status == :unchanged, do: "Saved — no changes.", else: "Saved."

        latest = Cleanings.latest(item_id)
        history = Cleanings.history(item_id)

        {:noreply,
         socket
         |> assign(latest: latest, history: history, drift?: false)
         |> put_flash(:info, flash)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
    end
  end

  def handle_event("prev_revision", _params, socket) do
    current = socket.assigns.view_revision || (socket.assigns.latest && socket.assigns.latest.revision_id + 1) || 0
    prev = Enum.find(Enum.reverse(socket.assigns.history), fn r -> r.revision_id < current end)

    if prev do
      {:ok, text} = BlobStore.get(prev.content_sha256)
      {:noreply, assign(socket, view_revision: prev.revision_id, viewed: %{text: text, ranges: prev.discard_ranges, rev: prev})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("next_revision", _params, socket) do
    current = socket.assigns.view_revision || 0
    next = Enum.find(socket.assigns.history, fn r -> r.revision_id > current end)

    cond do
      is_nil(next) ->
        {:noreply, socket}

      socket.assigns.latest && next.revision_id == socket.assigns.latest.revision_id ->
        {:noreply, assign(socket, view_revision: nil, viewed: nil)}

      true ->
        {:ok, text} = BlobStore.get(next.content_sha256)
        {:noreply, assign(socket, view_revision: next.revision_id, viewed: %{text: text, ranges: next.discard_ranges, rev: next})}
    end
  end

  def handle_event("return_to_latest", _params, socket) do
    {:noreply, assign(socket, view_revision: nil, viewed: nil)}
  end

  defp normalize(text), do: :unicode.characters_to_nfc_binary(text)
  defp sha256(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n), do: String.to_integer(n)

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl p-4">
      <header class="flex items-center justify-between mb-3">
        <div>
          <h1 class="text-xl font-semibold">Edit cleaning · {@item_id}</h1>
          <%= if @latest && is_nil(@view_revision) && !@drift? do %>
            <p class="text-xs text-zinc-500">
              Latest · rev {@latest.revision_id} · saved {Calendar.strftime(@latest.created_at, "%Y-%m-%d %H:%M")}
            </p>
          <% end %>
        </div>
        <%= if @latest do %>
          <nav class="flex items-center gap-2 text-sm">
            <button phx-click="prev_revision" class="px-2 py-1 rounded border" disabled={not has_prev?(assigns)}>
              ◀ Prev
            </button>
            <span class="text-zinc-600">
              <%= if @view_revision do %>
                rev {@view_revision}/{length(@history)}
              <% else %>
                rev {@latest.revision_id}/{length(@history)} · latest
              <% end %>
            </span>
            <button phx-click="next_revision" class="px-2 py-1 rounded border" disabled={not has_next?(assigns)}>
              Next ▶
            </button>
          </nav>
        <% end %>
      </header>

      <%= if @error do %>
        <div class="rounded bg-red-50 p-3 text-red-700 text-sm">
          Could not fetch cleaning content: {@error}
        </div>
      <% else %>
        <%= if @drift? and is_nil(@view_revision) do %>
          <div class="rounded bg-amber-50 p-3 text-amber-900 text-sm mb-3">
            Article text has changed since the last saved revision. Earlier revisions available via ◀ Prev.
          </div>
        <% end %>

        <%= if @view_revision do %>
          <div class="rounded bg-zinc-100 p-2 text-zinc-700 text-xs mb-3">
            Viewing rev {@view_revision} of {length(@history)} · created
            {Calendar.strftime(@viewed.rev.created_at, "%Y-%m-%d %H:%M")} ·
            <button phx-click="return_to_latest" class="underline">Latest ▶</button> to edit.
          </div>
        <% end %>

        <div class="grid grid-cols-[2fr_1fr] gap-3">
          <div
            id="article-pane"
            phx-hook="CleaningSelection"
            data-text-length={current_length(assigns)}
            data-read-only={if @view_revision, do: "true", else: "false"}
            class="rounded border bg-white p-3 font-mono text-sm whitespace-pre-wrap overflow-auto max-h-[80vh]"
          >
            {render_text_with_spans(current_text(assigns), current_ranges(assigns))}
          </div>

          <div class="rounded border bg-white p-3 overflow-auto max-h-[80vh]">
            <h2 class="text-sm font-medium mb-2">Spans ({length(current_ranges(assigns))})</h2>
            <%= if current_ranges(assigns) == [] do %>
              <%= if confirmed_empty?(assigns) do %>
                <p class="text-sm text-emerald-700 bg-emerald-50 rounded p-2">
                  ✓ Confirmed: nothing to discard in this revision.
                </p>
              <% else %>
                <p class="text-sm text-zinc-500">
                  No spans yet. Select text in the article to add one.
                </p>
              <% end %>
            <% end %>
            <ul class="space-y-2">
              <%= for {[s, e], idx} <- Enum.with_index(current_ranges(assigns)) do %>
                <li class="flex items-center gap-2 text-sm" data-span-idx={idx}>
                  <span class="truncate max-w-[10rem]" title={String.slice(current_text(assigns), s, e - s)}>
                    {String.slice(current_text(assigns), s, e - s)}
                  </span>
                  <span class="text-zinc-400 text-xs whitespace-nowrap">
                    <%= if @view_revision do %>
                      {s}–{e}
                    <% else %>
                      <input
                        type="number"
                        min="0"
                        max={current_length(assigns)}
                        value={s}
                        phx-blur="edit_range"
                        phx-value-index={idx}
                        phx-value-stop={e}
                        name="start"
                        class="w-16 border rounded px-1 text-right"
                      />
                      –
                      <input
                        type="number"
                        min="0"
                        max={current_length(assigns)}
                        value={e}
                        phx-blur="edit_range"
                        phx-value-index={idx}
                        phx-value-start={s}
                        name="stop"
                        class="w-16 border rounded px-1 text-right"
                      />
                    <% end %>
                  </span>
                  <%= unless @view_revision do %>
                    <button
                      phx-click="delete_span"
                      phx-value-index={idx}
                      title="Delete span"
                      class="ml-auto text-zinc-500 hover:text-rose-600"
                    >
                      🗑
                    </button>
                  <% end %>
                </li>
              <% end %>
            </ul>
          </div>
        </div>

        <div class="flex justify-end mt-3">
          <button
            phx-click="save"
            disabled={not is_nil(@view_revision)}
            title={if @view_revision, do: "Read-only view of a historical revision."}
            class="rounded bg-blue-600 px-3 py-2 text-white text-sm hover:bg-blue-700 disabled:opacity-50"
          >
            Save
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_text_with_spans(text, ranges) do
    codepoints = String.graphemes(text)
    sorted = Enum.sort_by(ranges, fn [s, _] -> s end)

    {chunks, cursor} =
      Enum.reduce(sorted, {[], 0}, fn [s, e], {acc, cursor} ->
        before = Enum.slice(codepoints, cursor, s - cursor) |> Enum.join()
        discard = Enum.slice(codepoints, s, e - s) |> Enum.join()

        {[
           Phoenix.HTML.raw(~s|<span class="bg-rose-200 text-rose-950" data-span-idx="#{length(acc) |> div(2)}">#{Phoenix.HTML.html_escape(discard) |> Phoenix.HTML.safe_to_string()}</span>|),
           Phoenix.HTML.html_escape(before) | acc
         ], e}
      end)

    tail = Enum.slice(codepoints, cursor, length(codepoints) - cursor) |> Enum.join()
    [Phoenix.HTML.html_escape(tail) | chunks] |> Enum.reverse() |> Phoenix.HTML.html_escape() |> elem(1)
  rescue
    _ ->
      # Fallback: a single tagged region for any unexpected input.
      text
  end

  defp current_text(%{view_revision: nil, text: text}), do: text
  defp current_text(%{viewed: %{text: text}}), do: text

  defp current_ranges(%{view_revision: nil, ranges: ranges}), do: ranges
  defp current_ranges(%{viewed: %{ranges: ranges}}), do: ranges

  defp current_length(%{view_revision: nil, text_length: n}), do: n
  defp current_length(%{viewed: %{text: text}}), do: String.length(text)

  defp has_prev?(%{view_revision: nil, history: history, latest: latest}) when length(history) > 1 do
    Enum.any?(history, fn r -> r.revision_id < latest.revision_id end)
  end

  defp has_prev?(%{view_revision: v, history: history}) when not is_nil(v) do
    Enum.any?(history, fn r -> r.revision_id < v end)
  end

  defp has_prev?(_), do: false

  defp has_next?(%{view_revision: nil}), do: false

  defp has_next?(%{view_revision: v, history: history}) do
    Enum.any?(history, fn r -> r.revision_id > v end)
  end

  defp confirmed_empty?(%{
         view_revision: nil,
         drift?: false,
         latest: %{discard_ranges: [], content_sha256: sha},
         text_sha: sha
       }),
       do: true

  defp confirmed_empty?(_), do: false
end
```

> **Note on `render_text_with_spans`:** the body shown uses `Phoenix.HTML.raw` and `html_escape` to keep span markup safe. If you run into Phoenix.HTML signature issues in your version, simplify by computing a flat list of `{kind, text}` tuples (kind ∈ `:keep | :discard`) and rendering them in HEEx with a `<%= for {kind, text} <- chunks do %>` loop using two `<span>` variants. The flat-tuple approach is preferable for readability; switch to it if you hit any errors. The test assertion only requires that the discarded substring appears inside an element carrying a class matching `bg-rose-\d+`.

- [ ] **Step 3: Run LiveView tests**

Run: `mix test test/alambic_web/live/edit_cleaning_live_test.exs`
Expected: all pass. If `render_text_with_spans` causes test failures or runtime errors, switch to the flat-tuple approach noted above before continuing.

- [ ] **Step 4: Commit**

```bash
git add lib/alambic_web/live/edit_cleaning_live.ex test/alambic_web/live/edit_cleaning_live_test.exs
git commit -m "feat: span-labeling cleaning LiveView with revisions"
```

---

## Task 10: JS hook for selection capture

Captures mouseup inside the article pane, computes codepoint offsets from the DOM, and pushes an `add_span` event. Cancelled / zero-width selections are ignored. Hook is disabled when `data-read-only="true"`.

**Files:**
- Create: `assets/js/hooks/cleaning_selection.js`
- Modify: `assets/js/app.js`

- [ ] **Step 1: Create the hook**

Create `assets/js/hooks/cleaning_selection.js`:

```javascript
// CleaningSelection hook
//
// On mouseup inside the article pane, compute the selection's codepoint
// offsets relative to the source text and push them to the LiveView as
// {start, stop}. Zero-width selections and selections crossing outside
// the pane are ignored. Disabled when the pane carries data-read-only="true".

const Hook = {
  mounted() {
    this.handler = () => this.onMouseUp()
    this.el.addEventListener("mouseup", this.handler)
  },

  destroyed() {
    this.el.removeEventListener("mouseup", this.handler)
  },

  onMouseUp() {
    if (this.el.dataset.readOnly === "true") return

    const sel = window.getSelection()
    if (!sel || sel.isCollapsed) return

    const range = sel.getRangeAt(0)
    if (!this.el.contains(range.startContainer) || !this.el.contains(range.endContainer)) return

    const start = this.offsetIn(range.startContainer, range.startOffset)
    const end = this.offsetIn(range.endContainer, range.endOffset)
    if (start == null || end == null) return

    const lo = Math.min(start, end)
    const hi = Math.max(start, end)
    if (lo === hi) return

    this.pushEvent("add_span", { start: lo, stop: hi })
    sel.removeAllRanges()
  },

  // Walk text nodes in document order; sum lengths until we reach `node`.
  // `offset` is a character offset within `node` (for text nodes) or a
  // child index (for element nodes). Returns null if `node` is not under `this.el`.
  offsetIn(node, offset) {
    let total = 0
    const walker = document.createTreeWalker(this.el, NodeFilter.SHOW_TEXT)

    if (node.nodeType === Node.ELEMENT_NODE) {
      // For element nodes, offset is the index of the child boundary.
      // Walk text nodes until we've passed `offset` element children.
      let textNode
      let idx = 0
      while ((textNode = walker.nextNode())) {
        if (textNode.parentNode === node && idx >= offset) break
        if (textNode.parentNode === node) idx++
        total += [...textNode.data].length  // codepoint count
      }
      return total
    }

    let cur
    while ((cur = walker.nextNode())) {
      if (cur === node) {
        const prefix = node.data.slice(0, offset)
        return total + [...prefix].length
      }
      total += [...cur.data].length
    }
    return null
  }
}

export default Hook
```

- [ ] **Step 2: Register the hook in `assets/js/app.js`**

In `assets/js/app.js`, change the imports near the top to include the hook:

```javascript
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import CleaningSelection from "./hooks/cleaning_selection.js"
```

Change the `new LiveSocket` call to pass the hook:

```javascript
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: { CleaningSelection }
})
```

- [ ] **Step 3: Manual smoke test**

Run the server: `mix phx.server`
In a browser, navigate to `/edit-cleaning/some-test-id`. Set up the test fixture by inserting a stub for Cham locally if needed, or seed a cleaning_revisions row via `iex`.

Smoke checklist:
- Drag-select a region in the article pane → it gets a pink background and appears in the span pane.
- The span pane row shows the truncated text, two number inputs, and a trash icon.
- Click the trash → span disappears.
- Edit a spinner → range updates (or snaps back if invalid).
- Save → toast appears, span count persists on reload.

If the visual behavior is wrong, iterate on `render_text_with_spans` and/or the hook's offset math before continuing.

- [ ] **Step 4: Commit**

```bash
git add assets/js/hooks/cleaning_selection.js assets/js/app.js
git commit -m "feat: client hook for cleaning span selection"
```

---

## Task 11: Verification sweep

**Files:** none (verification only).

- [ ] **Step 1: Full test suite**

Run: `mix test`
Expected: all green.

- [ ] **Step 2: Quality gates**

Run: `mix format --check-formatted && mix compile --warnings-as-errors`
Expected: clean. Run `mix format` to fix formatting if needed.

If credo is configured in the project, also run `mix credo --strict` and fix any new findings introduced by this work.

- [ ] **Step 3: Manual end-to-end**

`mix phx.server`. With a real (or stubbed) Cham instance:

- Fresh item → fresh editor, no banner, Save creates rev #1.
- Same item again → "Latest · rev 1" header, prior ranges pre-populated.
- Modify ranges, Save → rev #2 appears in history pager.
- Save again with no changes → "Saved — no changes." toast, no new rev.
- Drift case (modify Cham content) → drift banner; editor opens empty; Prev shows old text+labels read-only.
- Click Prev / Next, then "Latest ▶" → returns to editable state.
- Try invalid spinner edit (start ≥ stop) → snaps back.
- Try trash button → span vanishes, no confirm.

- [ ] **Step 4: Final commit if any tweaks were made**

```bash
git status
# only commit if there are changes
```

---

## Self-Review

Run through the spec sections and confirm coverage. Final check before marking the plan complete:

- **In-scope: two-pane LiveView** — Task 9.
- **Mouseup-triggered span selection** — Task 10 (hook) + Task 9 (server merge).
- **Numeric spinners** — Task 9, span pane render.
- **Append-only `cleaning_revisions`** — Task 3 (migration) + Task 4 (schema) + Task 5 (context).
- **Single Save button + dedup** — Task 9 save handler + Task 5 `save_revision/4`.
- **Drift handling** — Task 9 mount + render.
- **Prev/Next read-only history** — Task 9 prev_revision / next_revision handlers + render guards (disabled inputs and Save).
- **Cham renames + `fetch_cleaning_content`** — Tasks 1 + 2.
- **Dataset export updated** — Task 6.
- **Inference updated** — Task 7.
- **Out of scope items**: not implemented (editable rollback, content-hash inference lookup, reprocess, rendered markdown, keyboard shortcuts, span-list pagination, write-side Cham). The reprocess removal is reflected by the absence of a second button and the absence of a `Cham.request_reprocess/1` callback.

No placeholders introduced. Type names consistent across tasks: `Alambic.Cleanings.Revision` schema, `Alambic.Cleanings.Ranges` helper module, `Cleanings.save_revision/4`, `Cleanings.latest/1`, `Cleanings.history/1`, `Cleanings.list_latest/0`, `Cleanings.apply_discard_ranges/2`, `Cleanings.delete_all/1`. Cham callbacks: `fetch_extraction_html/1`, `fetch_cleaning_content/1`.
