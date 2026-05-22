# Alambic Cleaning UI — Design

**Goal:** Replace the placeholder cleaning LiveView with a span-based labeling UI that produces `discard_ranges` over codepoint-indexed cleaning text. Add an append-only revision history; navigate prior revisions read-only; handle source-text drift.

**Status:** Design only. No code yet.

---

## Scope

**In scope**
- Two-pane LiveView at `/clean/{item_id}`: raw cleaning source on the left, span list on the right.
- Mouseup-triggered span selection with overlap merging and per-row trash deletion.
- Numeric spinners on each span row for accessibility (manual range tuning).
- Append-only `cleaning_revisions` table; drop the current single-row `cleanings` table (no data exists).
- A single "Save" button with revision dedup.
- Drift handling: when live text differs from the latest revision, open the editor on live text with empty `discard_ranges` and surface a banner.
- Prev/Next pager over historical revisions, **read-only**.
- Cham client rename + new `fetch_cleaning_content/1` callback for `content.md`.

**Out of scope (explicit)**
- Editable historical revisions (rollback). Can be added later; cannot be removed once shipped.
- Content-hash-based inference lookup (matching annotations across `item_id`s by `content_sha256`). Tracked as a follow-up in memory.
- Token-level or word-level labels — discard spans only.
- Rendered-markdown view of the cleaning content. Source view only.
- Keyboard shortcuts beyond browser defaults.
- Pagination of the span list (a vertical-scroll pane is sufficient for v1).
- Triggering Cham reprocess. Cham has the endpoint but Alambic remains read-only toward it for now (matches the scaffolding decision). The dataset-export endpoints are how training pulls new labels; archive reprocess is a separate concern.

---

## Data model

### Migration

Drop `cleanings`; introduce `cleaning_revisions`.

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

Notes
- Per-item monotonic `revision_id`. Allocate as `(SELECT COALESCE(MAX(revision_id), 0) + 1 FROM cleaning_revisions WHERE item_id = $1)` inside the insert transaction.
- No `confirmed_at`/`updated_at` distinction — one timestamp per revision, `created_at`.
- `model_version` carries the inference model that produced the *seed* labels for this revision, if any. Null when the labels are entirely human-authored (drift case or fresh manual labeling).
- No `updated_at` on the table; the dataset export's `updated_at` derivation becomes `max(created_at) per item_id`.

### Schema

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

  # changeset validates: 64-hex sha, ranges are [start, stop] with 0 <= start < stop,
  # non-overlapping, sorted ascending. Same rules as today's Cleanings.Cleaning.
end
```

The `Alambic.Cleanings.Cleaning` schema and module are removed. `Alambic.Cleanings` context is restructured:

```
Alambic.Cleanings
├── latest(item_id)                   :: %Revision{} | nil
├── history(item_id)                  :: [%Revision{}]   # asc by revision_id
├── save_revision(item_id, text, ranges, opts \\ [])
│     # NFC-normalizes text, puts blob, dedups against latest, inserts row if new.
│     # opts: :model_version
│     :: {:ok, %Revision{}, :inserted | :unchanged}
├── apply_discard_ranges(text, ranges)
└── delete_all(item_id)               # cascade-deletes blobs after row delete
```

### Dataset-export impact

`Alambic.Datasets.export_parquet(:cleaning)` currently iterates `Cleanings.list_all()` and emits one row per item. After this change it should iterate the **latest revision per item** by default. A separate "all revisions" export is a future option, not required now. The parquet schema gains no columns; `prior_model_version` is sourced from `latest.model_version`, `confirmed_at` and `updated_at` both come from `latest.created_at`.

The HTTP endpoint shape (`/api/datasets/cleaning/rows.parquet`) is unchanged.

---

## Cham client

Rename and add. Current contract:
- `Cham.fetch_html/1` → `Cham.fetch_extraction_html/1`
- New: `Cham.fetch_cleaning_content/1` returns the post-extraction markdown blob.

```elixir
defmodule Alambic.Cham do
  @callback fetch_extraction_html(item_id :: String.t()) :: {:ok, binary} | {:error, term}
  @callback fetch_cleaning_content(item_id :: String.t()) :: {:ok, binary} | {:error, term}

  def fetch_extraction_html(item_id), do: impl().fetch_extraction_html(item_id)
  def fetch_cleaning_content(item_id), do: impl().fetch_cleaning_content(item_id)

  defp impl, do: Application.fetch_env!(:alambic, :cham_impl)
end
```

HTTP implementation: same URL pattern as today, but the filename comes from `:cham_cleaning_content_filename` (default `"content.md"`).

Config additions
- `:cham_cleaning_content_filename` (config + runtime + test)
- The existing `:cham_raw_html_filename` is renamed to `:cham_extraction_html_filename` for symmetry.

No write-side Cham callbacks. The client remains read-only.

---

## LiveView — `/clean/:item_id`

### Mount

1. Fetch live cleaning content via `Cham.fetch_cleaning_content(item_id)`. If 404 / error, render an error pane with a Retry button.
2. NFC-normalize the live text, compute its sha256.
3. Look up `Cleanings.latest(item_id)`. Three cases:
   - **No prior revision** → editor opens on live text, empty `discard_ranges`, no drift banner. Save creates revision #1.
   - **Latest matches live hash** → editor opens on live text, latest `discard_ranges` pre-populated. Header chip: "Latest · rev N · saved YYYY-MM-DD HH:MM".
   - **Latest hash differs** → editor opens on live text, empty `discard_ranges`. Banner: "Article text has changed since the last saved revision. Earlier revisions available via ◀ Prev." Save creates a new revision with `revision_id = latest + 1`.

### Layout

Single page, two columns under a top bar:

```
┌──────────────────────────────────────────────────────────────────────┐
│ Edit cleaning · {item_id}     [◀ Prev] [rev N/M · 2026-05-19] [Next ▶]│
│ [optional drift banner]                                              │
├───────────────────────────────────┬──────────────────────────────────┤
│ Article pane                      │ Span pane                        │
│ <monospace, soft-wrapped>         │  • Sponsored by foo              │
│  source text with highlighted     │    36–61  [trash]               │
│  ranges                           │                                  │
│                                   │  • Subscribe today               │
│                                   │   124–138 [trash]               │
│                                   │                                  │
│                                   │                                  │
├───────────────────────────────────┴──────────────────────────────────┤
│                                                                [Save]│
└──────────────────────────────────────────────────────────────────────┘
```

The two panes share vertical scroll independently. The article pane is `font-mono` and `whitespace-pre-wrap` so codepoint offsets equal browser-visible offsets minus the cumulative discard styling.

### Article pane

- Renders the source as a sequence of `<span>` runs derived from the sorted `discard_ranges`. Discarded spans get a high-contrast pink/red background (e.g. Tailwind `bg-rose-200` with `text-rose-950`) and a `data-span-idx={n}` attribute. The goal is unmissable at a glance — not subtle. Kept runs are bare text nodes.
- A LiveView hook captures `selectionchange` / `mouseup` on the article pane and computes the selection's start/end codepoint offsets relative to the source text. The hook pushes `{"add_span", start, stop}` to the server. Cancelled selections (collapsed or zero-width) are ignored.
- Offset computation is done client-side from the rendered DOM: walk text nodes in document order, summing their `length`s until the selection's anchor/focus nodes are reached. This works because the rendered text is the source text byte-for-byte (no markdown rendering).
- Server merges the new range with any overlapping or touching existing ranges, sorts, and reassigns to the in-memory `discard_ranges`. Re-renders.
- Hover bidirectionality: hovering a `data-span-idx` span adds a class to the corresponding span-pane row, and hovering a span-pane row adds an `outline` class to the matching DOM span. Implemented with two short JS handlers in the hook.

### Span pane

- One row per span, ordered by `start` ascending.
- Each row:
  - Truncated source text with `text-overflow: ellipsis` and `title={full_text}`.
  - Two number inputs (`<input type="number">` with arrow steppers) showing `start` and `end`. Min 0, max codepoint count, step 1. Commit on blur or Enter.
  - Trash icon button. One click. No confirm. Removes the span immediately.
- Spinner-edit validation: reject if `start < 0`, `end > length`, or `start >= end` — the input snaps back to its prior value without an error toast. Valid edits go through the same merge logic; if the edit causes overlap with an adjacent span, the spans merge into one (the edited span row vanishes into its neighbor; the focused input loses focus gracefully).
- Click on a row (not on the spinners or trash) scrolls the article pane so that span is at ~25% from the top, then briefly applies a `flash` class to the highlighted source span.

### Prev / Next navigation

- `Prev` is enabled if any revision exists with `revision_id < current_view`. `Next` is enabled when viewing history.
- Viewing history switches the article pane and span pane into **read-only** mode:
  - Article pane shows the historical revision's text (fetched from blob store by `content_sha256`).
  - Spinners are disabled. Trash icons hidden. Mouseup-add ignored.
  - Save button disabled, with a tooltip "Read-only view of a historical revision."
  - A clear visual band at the top: "Viewing rev N of M · created YYYY-MM-DD HH:MM · click 'Latest ▶' to edit."
- The pager shows numeric `rev N/M` plus the created-at timestamp.
- Clicking "Latest ▶" returns to the live-text editing state (rerun the mount logic).

### Save semantics

- **Save** (`phx-click="save"`): call `Cleanings.save_revision/4`. The context dedups against the latest revision; if `(content_sha256, discard_ranges)` match exactly, no row is inserted and the function returns `{:ok, latest, :unchanged}`. Mark the `review_queue` entry resolved either way — the user clicked Save deliberately, meaning "I reviewed this." Toast: "Saved." or "Saved — no changes." Stay on the page.

---

## Error and edge states

| Condition | Behavior |
|---|---|
| Cham 404 on cleaning content | Error pane with a Retry button. No revision history shown (we don't know what `item_id` looks like; better not to mislead). |
| Cham network error | Same as 404 with the underlying error in small text. |
| Empty cleaning content (zero bytes) | Article pane shows a placeholder "Article content is empty." No spans possible. Save still works (records an empty-content revision). |
| User selects across the article pane → span pane boundary | Browser's normal selection extends outside the article pane; the hook ignores ranges where either endpoint is not inside the article-pane element. |
| User edits a spinner so the span shrinks to zero | Snaps back. (Equivalent to a delete; user can use the trash icon if that's the intent.) |
| Concurrent edits from a second tab | Last write wins. Each Save is a new revision; both will be in history. |
| Drift between page open and Save | At save time the LiveView submits `(displayed_content_sha256, discard_ranges)`. If the displayed sha differs from the live Cham content at that moment, the LiveView still records the revision against the displayed sha — that is the text the human looked at. A re-mount on the next visit will detect drift again. |

---

## Test plan

- `Cleanings` context unit tests: `save_revision/4` inserts on first call, dedups on identical second call, increments `revision_id` on a change, allocates per-item monotonically under concurrent saves.
- `apply_discard_ranges/2` unchanged (already covered).
- Merge logic unit tests on a pure helper: given a list of ranges and a new range, return the merged list.
- LiveView tests: mount with three fixtures — no prior revision, latest matches, latest drifts. Assert the right banner and the right pre-populated ranges.
- LiveView event tests: simulate `add_span` events; assert in-memory state after merges. Simulate `delete_span` with the trash icon; assert removal. Simulate `edit_range`; assert validation + merge.
- Save flow tests: clicking Save inserts a revision; clicking Save twice in a row with unchanged labels inserts only once but resolves the queue both times.
- Prev/Next tests: with two revisions, clicking Prev shows the older content and disables editing.

---

## Migration notes for the implementation plan

Sequential ordering matters because the dataset-export module depends on `Cleanings.list_all/0`:

1. Cham client rename: `fetch_html` → `fetch_extraction_html`, config key `:cham_raw_html_filename` → `:cham_extraction_html_filename`, callers updated. Touches `Alambic.Cham`, `Alambic.Cham.HTTP`, the test fake, `config/*.exs`, `EditExtractionLive`, and any tests referencing the old name.
2. Add `Cham.fetch_cleaning_content/1` callback + HTTP impl + fake.
3. Drop `cleanings` table; create `cleaning_revisions`; add new schema + context. Remove the old `Alambic.Cleanings.Cleaning` schema.
4. Update `Alambic.Datasets.export_parquet(:cleaning)` to use latest-per-item.
5. Update `Alambic.Inference.clean/2` to read the latest revision instead of the old `Cleanings.get/1`.
6. Replace `EditCleaningLive` with the new two-pane implementation.

Each step compiles and tests on its own.
