# Alambic Dataset Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose alambic's confirmed extraction and cleaning labels (plus their referenced HTML / markdown bytes) over HTTP so an external trainer can pull a fresh, content-addressed dataset.

**Architecture:** Replace the inline `html_snapshot` / `source_text` columns with a content-addressed filesystem blob store. The metadata tables carry only `content_sha256` references, labels, timestamps. Two new HTTP endpoints serve the dataset: `rows.parquet` (metadata, written via Explorer/Polars) and `blobs/:sha256` (raw bytes, gunzipped on read).

**Tech Stack:** Elixir 1.18 / Phoenix 1.7, Ecto, `:crypto` for sha256, `:zlib` for gzip, [Explorer](https://hexdocs.pm/explorer) (Polars NIF) for parquet.

**Out of scope (deliberately):**
- Authentication on the dataset endpoints (punted; will land with Cham auth).
- `?since=` incremental sync (full resync every pull).
- Schema migration of existing data (no production data exists).
- Blob garbage collection beyond row-delete cascades (oxen-side orphan detection handles it).

---

## File Structure

**New files:**
- `lib/alambic/blob_store.ex` — content-addressed filesystem store (put/get/delete).
- `lib/alambic/datasets.ex` — assembles per-stage parquet bytes from DB rows.
- `lib/alambic_web/controllers/dataset_controller.ex` — `rows.parquet` and `blobs/:sha256` endpoints.
- `test/alambic/blob_store_test.exs`
- `test/alambic/datasets_test.exs`
- `test/alambic_web/controllers/dataset_controller_test.exs`

**Modified files:**
- `mix.exs` — add `:explorer` dep.
- `config/config.exs`, `config/runtime.exs` — `:alambic, :blob_storage_path` setting.
- `priv/repo/migrations/20260521000002_create_extractions.exs` — rewrite schema (no data exists).
- `priv/repo/migrations/20260521000003_create_cleanings.exs` — rewrite schema.
- `lib/alambic/extractions/extraction.ex` — schema + changeset.
- `lib/alambic/cleanings/cleaning.ex` — schema + changeset.
- `lib/alambic/extractions.ex` — `save_with_html/2`, `delete/1`.
- `lib/alambic/cleanings.ex` — `save_with_text/2`, `delete/1`.
- `lib/alambic/inference.ex` — `clean/2` saved path applies `discard_ranges` to blob bytes.
- `lib/alambic_web/live/edit_extraction_live.ex` — calls `save_with_html/2`.
- `lib/alambic_web/live/edit_cleaning_live.ex` — calls `save_with_text/2`.
- `lib/alambic_web/router.ex` — three new dataset routes.

---

## Task 1: Add Explorer dependency

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add `:explorer` to deps list**

Edit the `deps/0` function in `mix.exs`, inserting after the `{:req, "~> 0.5"},` line:

```elixir
      {:explorer, "~> 0.10"},
```

- [ ] **Step 2: Fetch deps and confirm compile**

Run: `mix deps.get && mix compile`
Expected: exit 0, Explorer and its Rustler-precompiled artifact resolve cleanly.

- [ ] **Step 3: Commit**

```bash
git add mix.exs mix.lock
git commit -m "deps: add explorer for parquet export"
```

---

## Task 2: BlobStore module

**Files:**
- Create: `lib/alambic/blob_store.ex`
- Create: `test/alambic/blob_store_test.exs`
- Modify: `config/config.exs`, `config/runtime.exs`, `config/test.exs`

The blob store is content-addressed by sha256 of *raw* bytes. On disk, blobs are gzip-compressed and named `<sha256_hex>.gz`. Reads decompress and return raw bytes.

- [ ] **Step 1: Configure storage path**

Add to `config/config.exs`:

```elixir
config :alambic, :blob_storage_path, "tmp/blobs"
```

Add to `config/runtime.exs` inside the prod branch:

```elixir
    config :alambic, :blob_storage_path,
      System.get_env("BLOB_STORAGE_PATH") ||
        raise "environment variable BLOB_STORAGE_PATH is missing."
```

Add to `config/test.exs` (top-level):

```elixir
config :alambic, :blob_storage_path, Path.expand("../tmp/blobs_test", __DIR__)
```

- [ ] **Step 2: Write failing tests**

Create `test/alambic/blob_store_test.exs`:

```elixir
defmodule Alambic.BlobStoreTest do
  use ExUnit.Case, async: false

  alias Alambic.BlobStore

  setup do
    dir = Path.join(System.tmp_dir!(), "alambic_blobs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    prev = Application.get_env(:alambic, :blob_storage_path)
    Application.put_env(:alambic, :blob_storage_path, dir)
    on_exit(fn ->
      File.rm_rf!(dir)
      Application.put_env(:alambic, :blob_storage_path, prev)
    end)
    %{dir: dir}
  end

  test "put returns the sha256 hex of raw bytes" do
    {:ok, sha} = BlobStore.put("hello world")
    assert sha == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
  end

  test "get round-trips raw bytes" do
    {:ok, sha} = BlobStore.put("payload")
    assert {:ok, "payload"} = BlobStore.get(sha)
  end

  test "get returns :not_found for missing sha" do
    assert :not_found =
             BlobStore.get(String.duplicate("0", 64))
  end

  test "delete removes the blob", %{dir: dir} do
    {:ok, sha} = BlobStore.put("byebye")
    assert :ok = BlobStore.delete(sha)
    refute File.exists?(Path.join(dir, "#{sha}.gz"))
    assert :not_found = BlobStore.get(sha)
  end

  test "put is idempotent for identical content" do
    {:ok, sha1} = BlobStore.put("same")
    {:ok, sha2} = BlobStore.put("same")
    assert sha1 == sha2
  end
end
```

Run: `mix test test/alambic/blob_store_test.exs`
Expected: FAIL (module does not exist).

- [ ] **Step 3: Implement BlobStore**

Create `lib/alambic/blob_store.ex`:

```elixir
defmodule Alambic.BlobStore do
  @moduledoc """
  Content-addressed filesystem store. Keys are sha256 hex of raw bytes.
  On disk, blobs are gzip-compressed and named `<sha256>.gz`.
  """

  @spec put(iodata) :: {:ok, String.t()}
  def put(bytes) do
    raw = IO.iodata_to_binary(bytes)
    sha = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    path = path_for(sha)
    File.mkdir_p!(Path.dirname(path))

    unless File.exists?(path) do
      File.write!(path, :zlib.gzip(raw))
    end

    {:ok, sha}
  end

  @spec get(String.t()) :: {:ok, binary} | :not_found
  def get(sha) when is_binary(sha) do
    path = path_for(sha)

    case File.read(path) do
      {:ok, compressed} -> {:ok, :zlib.gunzip(compressed)}
      {:error, :enoent} -> :not_found
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(sha) when is_binary(sha) do
    case File.rm(path_for(sha)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
    end
  end

  defp path_for(sha) do
    Application.fetch_env!(:alambic, :blob_storage_path)
    |> Path.join("#{sha}.gz")
  end
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/alambic/blob_store_test.exs`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/alambic/blob_store.ex test/alambic/blob_store_test.exs config/config.exs config/runtime.exs config/test.exs
git commit -m "feat: content-addressed blob store"
```

---

## Task 3: Schema overhaul — extractions & cleanings

Drop `html_snapshot` / `source_text` (now in BlobStore). Replace `token_labels` with `discard_ranges`. Add `content_sha256` and `updated_at` to both tables. No data migration needed (no data exists; edit migrations in place).

**Files:**
- Modify: `priv/repo/migrations/20260521000002_create_extractions.exs`
- Modify: `priv/repo/migrations/20260521000003_create_cleanings.exs`
- Modify: `lib/alambic/extractions/extraction.ex`
- Modify: `lib/alambic/cleanings/cleaning.ex`

- [ ] **Step 1: Rewrite extractions migration**

Replace contents of `priv/repo/migrations/20260521000002_create_extractions.exs`:

```elixir
defmodule Alambic.Repo.Migrations.CreateExtractions do
  use Ecto.Migration

  def change do
    create table(:extractions, primary_key: false) do
      add :item_id, :string, primary_key: true
      add :xpath, :string, null: false
      add :content_sha256, :string, null: false, size: 64
      add :confirmed_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
      add :model_version, :string
    end

    create index(:extractions, [:updated_at])
  end
end
```

- [ ] **Step 2: Rewrite cleanings migration**

Replace contents of `priv/repo/migrations/20260521000003_create_cleanings.exs`:

```elixir
defmodule Alambic.Repo.Migrations.CreateCleanings do
  use Ecto.Migration

  def change do
    create table(:cleanings, primary_key: false) do
      add :item_id, :string, primary_key: true
      add :content_sha256, :string, null: false, size: 64
      add :discard_ranges, :jsonb, null: false, default: "[]"
      add :confirmed_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
      add :model_version, :string
    end

    create index(:cleanings, [:updated_at])
  end
end
```

- [ ] **Step 3: Update Extraction schema**

Replace contents of `lib/alambic/extractions/extraction.ex`:

```elixir
defmodule Alambic.Extractions.Extraction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:item_id, :string, autogenerate: false}
  schema "extractions" do
    field :xpath, :string
    field :content_sha256, :string
    field :confirmed_at, :utc_datetime
    field :updated_at, :utc_datetime
    field :model_version, :string
  end

  def changeset(extraction, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> Map.put_new(:confirmed_at, now)
      |> Map.put(:updated_at, now)

    extraction
    |> cast(attrs, [:item_id, :xpath, :content_sha256, :confirmed_at, :updated_at, :model_version])
    |> validate_required([:item_id, :xpath, :content_sha256, :confirmed_at, :updated_at])
    |> validate_format(:content_sha256, ~r/\A[a-f0-9]{64}\z/)
  end
end
```

- [ ] **Step 4: Update Cleaning schema**

Replace contents of `lib/alambic/cleanings/cleaning.ex`:

```elixir
defmodule Alambic.Cleanings.Cleaning do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:item_id, :string, autogenerate: false}
  schema "cleanings" do
    field :content_sha256, :string
    field :discard_ranges, {:array, {:array, :integer}}, default: []
    field :confirmed_at, :utc_datetime
    field :updated_at, :utc_datetime
    field :model_version, :string
  end

  def changeset(cleaning, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> Map.put_new(:confirmed_at, now)
      |> Map.put(:updated_at, now)

    cleaning
    |> cast(attrs, [
      :item_id,
      :content_sha256,
      :discard_ranges,
      :confirmed_at,
      :updated_at,
      :model_version
    ])
    |> validate_required([:item_id, :content_sha256, :confirmed_at, :updated_at])
    |> validate_format(:content_sha256, ~r/\A[a-f0-9]{64}\z/)
    |> validate_change(:discard_ranges, &validate_ranges/2)
  end

  defp validate_ranges(:discard_ranges, ranges) do
    Enum.reduce_while(ranges, [], fn
      [start, stop], _acc when is_integer(start) and is_integer(stop) and start >= 0 and stop > start ->
        {:cont, []}

      _bad ->
        {:halt, [discard_ranges: "must be list of [start, stop] with 0 <= start < stop"]}
    end)
  end
end
```

- [ ] **Step 5: Reset DB and verify compile**

Run: `mix ecto.drop --quiet && mix ecto.create --quiet && mix ecto.migrate`
Expected: clean migrate output.
Run: `mix compile --warnings-as-errors`
Expected: exit 0 (existing callers in extractions.ex/cleanings.ex/inference.ex/LiveViews will break — that's tasks 4-6).

> **Note:** This step intentionally breaks `mix compile`. Subsequent tasks restore it. Do not commit yet; commit at the end of task 6.

---

## Task 4: Extractions / Cleanings contexts wire to BlobStore

The contexts gain `save_with_html/2` and `save_with_text/2` which accept raw bytes, write to the blob store, then persist the metadata row. Old `save/1` is removed (no callers keep using it).

**Files:**
- Modify: `lib/alambic/extractions.ex`
- Modify: `lib/alambic/cleanings.ex`
- Create: `test/alambic/extractions_test.exs`
- Create: `test/alambic/cleanings_test.exs`

- [ ] **Step 1: Write failing extractions test**

Create `test/alambic/extractions_test.exs`:

```elixir
defmodule Alambic.ExtractionsTest do
  use Alambic.DataCase, async: false

  alias Alambic.{BlobStore, Extractions}

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

  test "save_with_html stores blob and persists row with its sha" do
    {:ok, row} = Extractions.save_with_html(%{item_id: "it1", xpath: "/html"}, "<html></html>")
    assert row.content_sha256 == :crypto.hash(:sha256, "<html></html>") |> Base.encode16(case: :lower)
    assert {:ok, "<html></html>"} = BlobStore.get(row.content_sha256)
  end

  test "delete removes row and blob" do
    {:ok, row} = Extractions.save_with_html(%{item_id: "it2", xpath: "/html"}, "<html>x</html>")
    :ok = Extractions.delete("it2")
    assert nil == Extractions.get("it2")
    assert :not_found = BlobStore.get(row.content_sha256)
  end
end
```

Run: `mix test test/alambic/extractions_test.exs`
Expected: FAIL (`save_with_html` undefined).

- [ ] **Step 2: Implement extractions context**

Replace contents of `lib/alambic/extractions.ex`:

```elixir
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
```

- [ ] **Step 3: Run extractions tests**

Run: `mix test test/alambic/extractions_test.exs`
Expected: 2 tests pass.

- [ ] **Step 4: Write failing cleanings test**

Create `test/alambic/cleanings_test.exs`:

```elixir
defmodule Alambic.CleaningsTest do
  use Alambic.DataCase, async: false

  alias Alambic.{BlobStore, Cleanings}

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

  test "save_with_text persists with content hash and ranges" do
    {:ok, row} =
      Cleanings.save_with_text(
        %{item_id: "c1", discard_ranges: [[0, 5], [10, 20]]},
        "Hello world this is text"
      )

    expected_sha =
      :crypto.hash(:sha256, "Hello world this is text") |> Base.encode16(case: :lower)

    assert row.content_sha256 == expected_sha
    assert row.discard_ranges == [[0, 5], [10, 20]]
  end

  test "save_with_text rejects overlapping or inverted ranges" do
    {:error, cs} =
      Cleanings.save_with_text(%{item_id: "c2", discard_ranges: [[5, 5]]}, "abc")

    refute cs.valid?
  end

  test "delete removes row and blob" do
    {:ok, row} = Cleanings.save_with_text(%{item_id: "c3", discard_ranges: []}, "abcdef")
    :ok = Cleanings.delete("c3")
    assert nil == Cleanings.get("c3")
    assert :not_found = BlobStore.get(row.content_sha256)
  end
end
```

Run: `mix test test/alambic/cleanings_test.exs`
Expected: FAIL.

- [ ] **Step 5: Implement cleanings context**

Replace contents of `lib/alambic/cleanings.ex`:

```elixir
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
```

- [ ] **Step 6: Run cleanings tests**

Run: `mix test test/alambic/cleanings_test.exs`
Expected: 3 tests pass.

---

## Task 5: Fix Inference.clean for new schema

The saved-cleaning branch previously returned `source_text` verbatim — it never applied the labels. With `discard_ranges` + blob, do it correctly.

**Files:**
- Modify: `lib/alambic/inference.ex`

- [ ] **Step 1: Write failing inference test**

Append to (or create) `test/alambic/inference_test.exs`:

```elixir
defmodule Alambic.InferenceTest do
  use Alambic.DataCase, async: false

  alias Alambic.{Cleanings, Inference}

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

  test "clean returns kept text after discarding ranges" do
    {:ok, _} =
      Cleanings.save_with_text(
        %{item_id: "x1", discard_ranges: [[0, 6]]},
        "drop me keep me"
      )

    assert {:ok, %{cleaned_text: "keep me", source: :saved}} = Inference.clean("x1", "ignored")
  end
end
```

Run: `mix test test/alambic/inference_test.exs`
Expected: FAIL (returns old source_text).

- [ ] **Step 2: Update Inference.clean saved branch**

In `lib/alambic/inference.ex`, replace the `def clean/2` function:

```elixir
  def clean(item_id, text) do
    case Cleanings.get(item_id) do
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

- [ ] **Step 3: Run tests**

Run: `mix test test/alambic/inference_test.exs`
Expected: pass.

---

## Task 6: Update LiveViews

**Files:**
- Modify: `lib/alambic_web/live/edit_extraction_live.ex`
- Modify: `lib/alambic_web/live/edit_cleaning_live.ex`

The placeholder UIs already have `raw_html` in socket assigns. They just need to call the new save functions.

- [ ] **Step 1: Update edit_extraction_live.ex confirm handler**

In `lib/alambic_web/live/edit_extraction_live.ex`, replace `handle_event("confirm", ...)`:

```elixir
  def handle_event("confirm", _params, socket) do
    {:ok, _} =
      Extractions.save_with_html(
        %{item_id: socket.assigns.item_id, xpath: @placeholder_xpath},
        socket.assigns.raw_html || ""
      )

    :ok = ReviewQueue.resolve(socket.assigns.item_id, :extraction)
    {:noreply, put_flash(socket, :info, "Extraction confirmed.")}
  end
```

- [ ] **Step 2: Update edit_cleaning_live.ex confirm handler**

In `lib/alambic_web/live/edit_cleaning_live.ex`, replace `handle_event("confirm", ...)`:

```elixir
  def handle_event("confirm", _params, socket) do
    {:ok, _} =
      Cleanings.save_with_text(
        %{item_id: socket.assigns.item_id, discard_ranges: []},
        socket.assigns.raw_html || ""
      )

    :ok = ReviewQueue.resolve(socket.assigns.item_id, :cleaning)
    {:noreply, put_flash(socket, :info, "Cleaning confirmed.")}
  end
```

(`raw_html` is a placeholder for what will later be Cham-supplied markdown; the LiveView still only stores html bytes for now. Fine — the dataset cares about hash agreement, not content type.)

- [ ] **Step 3: Full compile + test sweep**

Run: `mix compile --warnings-as-errors`
Expected: exit 0.
Run: `mix test`
Expected: all green (existing LiveView tests, if any, still pass — they may need similar updates; fix any breakage in the same step).

- [ ] **Step 4: Commit tasks 3–6 together**

```bash
git add -A
git commit -m "feat: content-addressed schema + blob-backed contexts"
```

---

## Task 7: Datasets module — parquet export

Build a single function per stage that returns parquet bytes. Schema:

- **extraction**: `item_id: utf8, content_sha256: utf8, xpath: utf8, confirmed_at: int64 (unix s), updated_at: int64 (unix s), prior_model_version: utf8 nullable`
- **cleaning**: `item_id: utf8, content_sha256: utf8, discard_ranges: list[list[int32]], confirmed_at: int64, updated_at: int64, prior_model_version: utf8 nullable`

**Files:**
- Create: `lib/alambic/datasets.ex`
- Create: `test/alambic/datasets_test.exs`

- [ ] **Step 1: Write failing test**

Create `test/alambic/datasets_test.exs`:

```elixir
defmodule Alambic.DatasetsTest do
  use Alambic.DataCase, async: false

  alias Alambic.{Cleanings, Datasets, Extractions}

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

  test "extraction parquet round-trips one row" do
    {:ok, _} = Extractions.save_with_html(%{item_id: "i1", xpath: "/html/body"}, "<html></html>")
    bytes = Datasets.export_parquet(:extraction) |> IO.iodata_to_binary()

    path = Path.join(System.tmp_dir!(), "alambic_t_#{System.unique_integer([:positive])}.parquet")
    File.write!(path, bytes)
    df = Explorer.DataFrame.from_parquet!(path)
    File.rm!(path)

    assert Explorer.DataFrame.n_rows(df) == 1
    row = Explorer.DataFrame.to_rows(df) |> hd()
    assert row["item_id"] == "i1"
    assert row["xpath"] == "/html/body"
    assert String.length(row["content_sha256"]) == 64
  end

  test "cleaning parquet carries discard_ranges as list of lists" do
    {:ok, _} =
      Cleanings.save_with_text(%{item_id: "c1", discard_ranges: [[0, 3], [7, 10]]}, "abcdefghij")

    bytes = Datasets.export_parquet(:cleaning) |> IO.iodata_to_binary()
    path = Path.join(System.tmp_dir!(), "alambic_t_#{System.unique_integer([:positive])}.parquet")
    File.write!(path, bytes)
    df = Explorer.DataFrame.from_parquet!(path)
    File.rm!(path)

    row = Explorer.DataFrame.to_rows(df) |> hd()
    assert row["item_id"] == "c1"
    assert row["discard_ranges"] == [[0, 3], [7, 10]]
  end

  test "empty stage returns valid empty parquet" do
    bytes = Datasets.export_parquet(:extraction) |> IO.iodata_to_binary()
    path = Path.join(System.tmp_dir!(), "alambic_t_#{System.unique_integer([:positive])}.parquet")
    File.write!(path, bytes)
    df = Explorer.DataFrame.from_parquet!(path)
    File.rm!(path)
    assert Explorer.DataFrame.n_rows(df) == 0
  end
end
```

Run: `mix test test/alambic/datasets_test.exs`
Expected: FAIL (module missing).

- [ ] **Step 2: Implement Datasets module**

Create `lib/alambic/datasets.ex`:

```elixir
defmodule Alambic.Datasets do
  @moduledoc """
  Builds parquet exports of confirmed labels for each stage.
  """

  alias Alambic.{Cleanings, Extractions}
  alias Explorer.DataFrame

  @spec export_parquet(:extraction | :cleaning) :: iodata
  def export_parquet(:extraction) do
    rows = Extractions.list_all()

    df =
      DataFrame.new(%{
        "item_id" => Enum.map(rows, & &1.item_id),
        "content_sha256" => Enum.map(rows, & &1.content_sha256),
        "xpath" => Enum.map(rows, & &1.xpath),
        "confirmed_at" => Enum.map(rows, &DateTime.to_unix(&1.confirmed_at)),
        "updated_at" => Enum.map(rows, &DateTime.to_unix(&1.updated_at)),
        "prior_model_version" => Enum.map(rows, & &1.model_version)
      })

    to_parquet_bytes(df)
  end

  def export_parquet(:cleaning) do
    rows = Cleanings.list_all()

    df =
      DataFrame.new(%{
        "item_id" => Enum.map(rows, & &1.item_id),
        "content_sha256" => Enum.map(rows, & &1.content_sha256),
        "discard_ranges" => Enum.map(rows, & &1.discard_ranges),
        "confirmed_at" => Enum.map(rows, &DateTime.to_unix(&1.confirmed_at)),
        "updated_at" => Enum.map(rows, &DateTime.to_unix(&1.updated_at)),
        "prior_model_version" => Enum.map(rows, & &1.model_version)
      })

    to_parquet_bytes(df)
  end

  defp to_parquet_bytes(df) do
    path = Path.join(System.tmp_dir!(), "alambic_export_#{System.unique_integer([:positive])}.parquet")

    try do
      DataFrame.to_parquet!(df, path, compression: {:zstd, 3})
      File.read!(path)
    after
      File.rm(path)
    end
  end
end
```

- [ ] **Step 3: Run tests**

Run: `mix test test/alambic/datasets_test.exs`
Expected: 3 tests pass.

> **If discard_ranges fails type inference**, switch the column to a series with an explicit dtype: `Explorer.Series.from_list(rows_ranges, dtype: {:list, {:list, :s32}})`, and build `DataFrame.new/1` from a keyword list of series.

- [ ] **Step 4: Commit**

```bash
git add lib/alambic/datasets.ex test/alambic/datasets_test.exs
git commit -m "feat: parquet export of extraction and cleaning rows"
```

---

## Task 8: Dataset HTTP endpoints

Two endpoints per stage:
- `GET /api/datasets/:stage/rows.parquet` — octet-stream parquet bytes.
- `GET /api/datasets/:stage/blobs/:sha256` — octet-stream raw bytes, 404 if missing.

**Files:**
- Create: `lib/alambic_web/controllers/dataset_controller.ex`
- Create: `test/alambic_web/controllers/dataset_controller_test.exs`
- Modify: `lib/alambic_web/router.ex`

- [ ] **Step 1: Wire routes**

In `lib/alambic_web/router.ex`, inside `scope "/api", AlambicWeb`, after the `post "/clean"` line add:

```elixir
    get "/datasets/:stage/rows.parquet", DatasetController, :rows
    get "/datasets/:stage/blobs/:sha256", DatasetController, :blob
```

- [ ] **Step 2: Write failing controller test**

Create `test/alambic_web/controllers/dataset_controller_test.exs`:

```elixir
defmodule AlambicWeb.DatasetControllerTest do
  use AlambicWeb.ConnCase, async: false

  alias Alambic.{BlobStore, Extractions}

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

  test "GET /api/datasets/extraction/rows.parquet returns parquet bytes", %{conn: conn} do
    {:ok, _} = Extractions.save_with_html(%{item_id: "i1", xpath: "/html"}, "<html/>")
    conn = get(conn, ~p"/api/datasets/extraction/rows.parquet")
    assert response_content_type(conn, :octet_stream) =~ "octet-stream"
    body = response(conn, 200)
    # parquet magic header
    assert binary_part(body, 0, 4) == "PAR1"
  end

  test "GET /api/datasets/extraction/blobs/:sha returns raw bytes", %{conn: conn} do
    {:ok, row} = Extractions.save_with_html(%{item_id: "i1", xpath: "/html"}, "<html>hi</html>")
    conn = get(conn, ~p"/api/datasets/extraction/blobs/#{row.content_sha256}")
    assert response(conn, 200) == "<html>hi</html>"
  end

  test "GET blob returns 404 for missing sha", %{conn: conn} do
    missing = String.duplicate("0", 64)
    conn = get(conn, ~p"/api/datasets/extraction/blobs/#{missing}")
    assert response(conn, 404)
  end

  test "GET rows for unknown stage returns 404", %{conn: conn} do
    conn = get(conn, ~p"/api/datasets/banana/rows.parquet")
    assert response(conn, 404)
  end
end
```

Run: `mix test test/alambic_web/controllers/dataset_controller_test.exs`
Expected: FAIL (controller missing).

- [ ] **Step 3: Implement DatasetController**

Create `lib/alambic_web/controllers/dataset_controller.ex`:

```elixir
defmodule AlambicWeb.DatasetController do
  use AlambicWeb, :controller

  alias Alambic.{BlobStore, Datasets}

  @stages ~w(extraction cleaning)

  def rows(conn, %{"stage" => stage}) when stage in @stages do
    bytes = Datasets.export_parquet(String.to_existing_atom(stage))

    conn
    |> put_resp_content_type("application/octet-stream")
    |> put_resp_header("content-disposition", ~s|attachment; filename="rows.parquet"|)
    |> send_resp(200, bytes)
  end

  def rows(conn, _), do: send_resp(conn, 404, "unknown stage")

  def blob(conn, %{"stage" => stage, "sha256" => sha}) when stage in @stages do
    case BlobStore.get(sha) do
      {:ok, bytes} ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> send_resp(200, bytes)

      :not_found ->
        send_resp(conn, 404, "not found")
    end
  end

  def blob(conn, _), do: send_resp(conn, 404, "unknown stage")
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/alambic_web/controllers/dataset_controller_test.exs`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/alambic_web/controllers/dataset_controller.ex test/alambic_web/controllers/dataset_controller_test.exs lib/alambic_web/router.ex
git commit -m "feat: dataset HTTP endpoints (rows.parquet, blobs/:sha)"
```

---

## Task 9: Verification sweep

**Files:** none (verification only)

- [ ] **Step 1: Full suite**

Run: `mix test`
Expected: all green.

- [ ] **Step 2: Quality gates**

Run: `mix format --check-formatted && mix credo --strict && mix compile --warnings-as-errors`
Expected: all clean. Fix anything that fails as needed before continuing.

- [ ] **Step 3: Manual smoke**

Run: `mix phx.server` in a separate terminal.
In another: `curl -i http://localhost:4000/api/datasets/extraction/rows.parquet -o /tmp/rows.parquet`
Expected: 200, file written, `xxd /tmp/rows.parquet | head -1` shows `PAR1` magic.

- [ ] **Step 4: Final commit if any tweaks made**

```bash
git status
# only commit if there's anything to add
```

---

## Self-Review Checklist

- Schema overhaul covered: extractions ✓, cleanings ✓, both get `content_sha256` and `updated_at`.
- Blob store covered: put/get/delete, content-addressed, gzip-on-disk.
- Both stages exported as parquet ✓, blob endpoint serves raw bytes ✓.
- LiveView writers updated ✓; Inference.clean saved branch fixed ✓.
- No `?since=` filter (deliberate punt — full resync).
- No auth (deliberate punt).
- No new migration for in-place edits (no data exists, edited migrations directly).
- `Cleanings.apply_discard_ranges` used both in `Inference.clean` and tests; signature matches across uses.
