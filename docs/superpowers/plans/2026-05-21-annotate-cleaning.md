# /annotate-cleaning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bulk human-annotation workflow for cleanings at `GET /annotate-cleaning` that walks the review queue one item at a time, plus a `source` provenance column on `cleaning_revisions` so labels can be filtered by how they were produced.

**Architecture:** A new `source` string column on `cleaning_revisions` records provenance (`"human"`, `"model"`, `"llm_batch"`) — backfilled to `"human"` for existing rows since today only the LiveView writes revisions. `GET /annotate-cleaning` is a thin controller: it finds the highest-priority pending cleaning queue entry whose item has no revision and 302-redirects to `/edit-cleaning/:item_id?after=annotate`; when the queue is exhausted it renders an "all done" page. `EditCleaningLive` learns one new behavior: if mounted with `?after=annotate`, its existing save handler `push_navigate`s back to `/annotate-cleaning` after a successful save instead of staying on the edit page. No new editor UI — the bulk flow is a redirect loop through the existing editor.

Naming note: `source` is also used in `Alambic.Inference` response maps (`:saved | :saved_by_content | :model`) to indicate cache-vs-model dispatch. The new DB column is a *different* concept (provenance of the persisted row, not how the current request was served). They don't collide in code paths, but be aware when reading.

**Tech Stack:** Elixir / Phoenix LiveView, Ecto, PostgreSQL.

---

## File Structure

**Modify:**
- `lib/alambic/cleanings/revision.ex` — add `:source` field, validate inclusion
- `lib/alambic/cleanings.ex` — require `:source` in `save_revision/4`, add `next_for_annotation/0`
- `lib/alambic_web/live/edit_cleaning_live.ex` — pass `source: "human"` on save; read `?after=annotate` and redirect on save
- `lib/alambic_web/router.ex` — add `get "/annotate-cleaning"` route
- `test/alambic/cleanings_test.exs` — update existing `save_revision` calls; add `next_for_annotation` tests
- `test/alambic_web/live/edit_cleaning_live_test.exs` — update setup calls to pass `source`; add `after=annotate` redirect test
- `test/alambic/datasets_test.exs` — update setup calls to pass `source`
- `test/alambic/inference_test.exs` — update setup calls to pass `source`

**Create:**
- `priv/repo/migrations/20260521000006_add_source_to_cleaning_revisions.exs`
- `lib/alambic_web/controllers/annotate_cleaning_controller.ex`
- `lib/alambic_web/controllers/annotate_cleaning_html.ex` + `lib/alambic_web/controllers/annotate_cleaning_html/done.html.heex`
- `test/alambic_web/controllers/annotate_cleaning_controller_test.exs`

---

### Task 1: Migration — add `source` column to `cleaning_revisions`

**Files:**
- Create: `priv/repo/migrations/20260521000006_add_source_to_cleaning_revisions.exs`

- [ ] **Step 1: Write the migration**

```elixir
defmodule Alambic.Repo.Migrations.AddSourceToCleaningRevisions do
  use Ecto.Migration

  def change do
    alter table(:cleaning_revisions) do
      add :source, :string
    end

    # Backfill: today only EditCleaningLive writes revisions (model path does
    # not persist), and tests pass model_version only when simulating a model
    # row. Treat any pre-existing row with model_version IS NULL as human;
    # else model.
    execute(
      "UPDATE cleaning_revisions SET source = CASE WHEN model_version IS NULL THEN 'human' ELSE 'model' END",
      "UPDATE cleaning_revisions SET source = NULL"
    )

    alter table(:cleaning_revisions) do
      modify :source, :string, null: false
    end

    create constraint(:cleaning_revisions, :source_must_be_known,
             check: "source IN ('human', 'model', 'llm_batch')"
           )
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: applies the new migration without errors.

- [ ] **Step 3: Sanity-check the schema**

Run: `mix ecto.dump && grep -A1 'cleaning_revisions' priv/repo/structure.sql | head -30`
Expected: `source` column present, NOT NULL, with the check constraint.

If `priv/repo/structure.sql` isn't tracked in this repo, skip this step.

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/20260521000006_add_source_to_cleaning_revisions.exs
git commit -m "feat(cleanings): add source column to cleaning_revisions"
```

---

### Task 2: Add `:source` to the `Revision` schema

**Files:**
- Modify: `lib/alambic/cleanings/revision.ex`

- [ ] **Step 1: Write a failing schema test**

Append to `test/alambic/cleanings_test.exs` (inside the existing module, before the closing `end`):

```elixir
  test "Revision changeset requires source and rejects unknown values" do
    base = %{
      item_id: "x",
      revision_id: 1,
      content_sha256: String.duplicate("a", 64),
      discard_ranges: []
    }

    cs = Alambic.Cleanings.Revision.changeset(%Alambic.Cleanings.Revision{}, base)
    refute cs.valid?
    assert {"can't be blank", _} = cs.errors[:source]

    cs2 = Alambic.Cleanings.Revision.changeset(%Alambic.Cleanings.Revision{}, Map.put(base, :source, "bogus"))
    refute cs2.valid?
    assert cs2.errors[:source]

    cs3 = Alambic.Cleanings.Revision.changeset(%Alambic.Cleanings.Revision{}, Map.put(base, :source, "human"))
    assert cs3.valid?
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/alambic/cleanings_test.exs -k "Revision changeset"`
Expected: FAIL — `:source` isn't a field on the schema yet.

(`-k` may not be supported; use `--only line:<n>` or just run the whole file — failure pattern is what matters.)

- [ ] **Step 3: Add the field and validation**

Replace the schema block and changeset in `lib/alambic/cleanings/revision.ex` with:

```elixir
defmodule Alambic.Cleanings.Revision do
  use Ecto.Schema
  import Ecto.Changeset

  @sources ~w(human model llm_batch)

  @primary_key false
  schema "cleaning_revisions" do
    field :item_id, :string, primary_key: true
    field :revision_id, :integer, primary_key: true
    field :content_sha256, :string
    field :discard_ranges, {:array, {:array, :integer}}, default: []
    field :created_at, :utc_datetime
    field :model_version, :string
    field :source, :string
  end

  def sources, do: @sources

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
      :model_version,
      :source
    ])
    |> validate_required([:item_id, :revision_id, :content_sha256, :created_at, :source])
    |> validate_inclusion(:source, @sources)
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

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/alambic/cleanings_test.exs`
Expected: the new test passes; other tests in this file FAIL because `save_revision` doesn't yet plumb `:source` — that's fixed in Task 3.

- [ ] **Step 5: Commit**

```bash
git add lib/alambic/cleanings/revision.ex test/alambic/cleanings_test.exs
git commit -m "feat(cleanings): require source on Revision changeset"
```

---

### Task 3: Plumb `:source` through `Cleanings.save_revision/4`

**Files:**
- Modify: `lib/alambic/cleanings.ex`
- Modify: `test/alambic/cleanings_test.exs`
- Modify: `test/alambic/datasets_test.exs`
- Modify: `test/alambic/inference_test.exs`
- Modify: `test/alambic_web/live/edit_cleaning_live_test.exs`
- Modify: `lib/alambic_web/live/edit_cleaning_live.ex`

- [ ] **Step 1: Add a failing test for the new requirement**

Append to `test/alambic/cleanings_test.exs`:

```elixir
  test "save_revision/4 requires a :source opt" do
    assert_raise KeyError, fn ->
      Cleanings.save_revision("item-src", "hello", [], [])
    end
  end

  test "save_revision/4 persists the source value" do
    {:ok, %Revision{source: "human"}, :inserted} =
      Cleanings.save_revision("item-src-h", "hi", [], source: "human")

    {:ok, %Revision{source: "llm_batch"}, :inserted} =
      Cleanings.save_revision("item-src-l", "hi", [], source: "llm_batch")
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/alambic/cleanings_test.exs`
Expected: FAIL — `save_revision` doesn't require or persist `:source`.

- [ ] **Step 3: Update `Cleanings.save_revision/4` to require `:source`**

In `lib/alambic/cleanings.ex`, replace the `save_revision/4` head and `do_save/4` to fetch and pass through `:source`. Replace the existing definitions of `save_revision/4` and `do_save/4`:

```elixir
  @doc """
  NFC-normalizes `text`, stores it in the blob store, and inserts a new
  revision row unless it would be a no-op duplicate of the latest revision.

  Required: `opts[:source]` — one of `"human"`, `"model"`, `"llm_batch"`.
  Optional: `opts[:model_version]`, `opts[:created_at]`.

  Returns `{:ok, %Revision{}, :inserted | :unchanged}` on success or
  `{:error, :invalid_utf8}` if the text is not valid UTF-8.
  """
  def save_revision(item_id, text, discard_ranges, opts)
      when is_binary(item_id) and is_binary(text) and is_list(discard_ranges) do
    source = Keyword.fetch!(opts, :source)

    case :unicode.characters_to_nfc_binary(text) do
      normalized when is_binary(normalized) ->
        {:ok, sha} = BlobStore.put(normalized)
        do_save(item_id, sha, discard_ranges, Keyword.put(opts, :source, source))

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
            discard_ranges: ranges,
            source: Keyword.fetch!(opts, :source)
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
```

Also remove the default `opts \\ []` — `save_revision` now requires the opts list (callers must pass `[source: "..."]`). Update the function head accordingly: drop the `\\ []` default in the head line shown above.

- [ ] **Step 4: Update the production caller (`EditCleaningLive.handle_event("save")`)**

In `lib/alambic_web/live/edit_cleaning_live.ex`, change the existing line:

```elixir
    case Cleanings.save_revision(item_id, text, ranges) do
```

to:

```elixir
    case Cleanings.save_revision(item_id, text, ranges, source: "human") do
```

- [ ] **Step 5: Update all test call sites to pass `source: "human"` (or `"model"` when applicable)**

Use `git grep -nF 'Cleanings.save_revision(' test/` to enumerate. For each call that currently passes no opts, add `source: "human"`. For calls that currently pass `model_version: ...`, add `source: "model"` alongside.

Concrete sites (from the survey at plan-write time — verify with `git grep` in case anything shifted):
- `test/alambic/cleanings_test.exs:21` `save_revision("item-a", "hello world", [[0, 5]])` → add `, source: "human"`
- `test/alambic/cleanings_test.exs:29,32` → add `, source: "human"`
- `test/alambic/cleanings_test.exs:39,42,45` → add `, source: "human"`
- `test/alambic/cleanings_test.exs:52,53` → add `, source: "human"`
- `test/alambic/cleanings_test.exs:67,70` → add `, source: "human"`
- `test/alambic/cleanings_test.exs:77` (invalid UTF-8 test) → add `, source: "human"` so the source check doesn't pre-empt the utf-8 error path
- `test/alambic/cleanings_test.exs:85,86` → add `, source: "human"`
- `test/alambic/datasets_test.exs:38,52,53` → add `, source: "human"`
- `test/alambic/inference_test.exs:83,89,100,120,127,134` → add `, source: "human"`
- `test/alambic_web/live/edit_cleaning_live_test.exs:37,49,116,128,129,143` → add `, source: "human"`

Form to use when no opts present today:

```elixir
Cleanings.save_revision("item-a", "hello world", [[0, 5]], source: "human")
```

- [ ] **Step 6: Run the full test suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/alambic/cleanings.ex lib/alambic_web/live/edit_cleaning_live.ex test/
git commit -m "feat(cleanings): require :source in save_revision and pass \"human\" from edit UI"
```

---

### Task 4: `Cleanings.next_for_annotation/0`

Returns the highest-priority pending cleaning queue entry whose item has no revision yet, or `nil` if none. Skips items that already have any revision — once a human (or anything) has saved one, we don't re-show it in v1.

**Files:**
- Modify: `lib/alambic/cleanings.ex`
- Modify: `test/alambic/cleanings_test.exs`

- [ ] **Step 1: Write failing tests**

Append to `test/alambic/cleanings_test.exs`:

```elixir
  describe "next_for_annotation/0" do
    alias Alambic.ReviewQueue

    test "returns nil when the cleaning queue is empty" do
      assert Cleanings.next_for_annotation() == nil
    end

    test "returns the lowest-confidence pending cleaning entry with no revision" do
      for {id, c} <- [{"a", 0.9}, {"b", 0.1}, {"c", 0.5}] do
        {:ok, _} =
          ReviewQueue.enqueue(%{
            item_id: id,
            stage: :cleaning,
            confidence: c,
            model_version: "v1"
          })
      end

      assert %{item_id: "b"} = Cleanings.next_for_annotation()
    end

    test "skips items that already have a revision" do
      {:ok, _} =
        ReviewQueue.enqueue(%{
          item_id: "already-done",
          stage: :cleaning,
          confidence: 0.05,
          model_version: "v1"
        })

      {:ok, _} =
        ReviewQueue.enqueue(%{
          item_id: "todo",
          stage: :cleaning,
          confidence: 0.5,
          model_version: "v1"
        })

      {:ok, _, :inserted} =
        Cleanings.save_revision("already-done", "x", [], source: "human")

      assert %{item_id: "todo"} = Cleanings.next_for_annotation()
    end

    test "ignores extraction-stage queue entries" do
      {:ok, _} =
        ReviewQueue.enqueue(%{
          item_id: "x",
          stage: :extraction,
          confidence: 0.1,
          model_version: "v1"
        })

      assert Cleanings.next_for_annotation() == nil
    end

    test "ignores already-resolved queue entries" do
      {:ok, _} =
        ReviewQueue.enqueue(%{
          item_id: "r",
          stage: :cleaning,
          confidence: 0.1,
          model_version: "v1"
        })

      :ok = ReviewQueue.resolve("r", :cleaning)
      assert Cleanings.next_for_annotation() == nil
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/alambic/cleanings_test.exs`
Expected: FAIL — `Cleanings.next_for_annotation/0` is undefined.

- [ ] **Step 3: Implement `next_for_annotation/0`**

Add to `lib/alambic/cleanings.ex` (alongside `latest/1`, `history/1`, etc., and add `alias Alambic.ReviewQueue.Entry` near the existing aliases):

```elixir
  alias Alambic.ReviewQueue.Entry

  @doc """
  Returns the highest-priority pending cleaning-stage review queue entry whose
  item has no revision yet, or `nil` if none. Ordering matches
  `ReviewQueue.list_pending/0` (ascending confidence, then queued_at).
  """
  def next_for_annotation do
    from(e in Entry,
      where: e.stage == :cleaning and is_nil(e.resolved_at),
      where:
        fragment(
          "NOT EXISTS (SELECT 1 FROM cleaning_revisions r WHERE r.item_id = ?)",
          e.item_id
        ),
      order_by: [asc: e.confidence, asc: e.queued_at],
      limit: 1
    )
    |> Repo.one()
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mix test test/alambic/cleanings_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/alambic/cleanings.ex test/alambic/cleanings_test.exs
git commit -m "feat(cleanings): add next_for_annotation/0 queue walker"
```

---

### Task 5: `AnnotateCleaningController` + route + "all done" view

**Files:**
- Create: `lib/alambic_web/controllers/annotate_cleaning_controller.ex`
- Create: `lib/alambic_web/controllers/annotate_cleaning_html.ex`
- Create: `lib/alambic_web/controllers/annotate_cleaning_html/done.html.heex`
- Modify: `lib/alambic_web/router.ex`
- Create: `test/alambic_web/controllers/annotate_cleaning_controller_test.exs`

- [ ] **Step 1: Write failing controller tests**

Create `test/alambic_web/controllers/annotate_cleaning_controller_test.exs`:

```elixir
defmodule AlambicWeb.AnnotateCleaningControllerTest do
  use AlambicWeb.ConnCase, async: false

  alias Alambic.ReviewQueue

  test "redirects to /edit-cleaning/:item_id?after=annotate when work is pending", %{conn: conn} do
    {:ok, _} =
      ReviewQueue.enqueue(%{
        item_id: "low",
        stage: :cleaning,
        confidence: 0.1,
        model_version: "v1"
      })

    conn = get(conn, ~p"/annotate-cleaning")
    assert redirected_to(conn) == "/edit-cleaning/low?after=annotate"
  end

  test "renders the all-done page when the queue is empty", %{conn: conn} do
    conn = get(conn, ~p"/annotate-cleaning")
    assert html_response(conn, 200) =~ "All annotated"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/alambic_web/controllers/annotate_cleaning_controller_test.exs`
Expected: FAIL — route doesn't exist yet (`Phoenix.Router.NoRouteError` or compile error in `~p"/annotate-cleaning"`).

- [ ] **Step 3: Add the route**

In `lib/alambic_web/router.ex`, inside the browser scope, after the existing live routes:

```elixir
    get "/annotate-cleaning", AnnotateCleaningController, :next
```

- [ ] **Step 4: Implement the controller**

Create `lib/alambic_web/controllers/annotate_cleaning_controller.ex`:

```elixir
defmodule AlambicWeb.AnnotateCleaningController do
  use AlambicWeb, :controller

  alias Alambic.Cleanings

  def next(conn, _params) do
    case Cleanings.next_for_annotation() do
      nil ->
        render(conn, :done)

      %{item_id: item_id} ->
        redirect(conn, to: ~p"/edit-cleaning/#{item_id}?after=annotate")
    end
  end
end
```

- [ ] **Step 5: Implement the HTML module and template**

Create `lib/alambic_web/controllers/annotate_cleaning_html.ex`:

```elixir
defmodule AlambicWeb.AnnotateCleaningHTML do
  use AlambicWeb, :html

  embed_templates "annotate_cleaning_html/*"
end
```

Create `lib/alambic_web/controllers/annotate_cleaning_html/done.html.heex`:

```heex
<div class="mx-auto max-w-xl p-6 text-center">
  <h1 class="text-2xl font-semibold mb-2">All annotated</h1>
  <p class="text-zinc-600">
    No pending cleaning items in the review queue. Check back when the model flags more low-confidence items.
  </p>
</div>
```

- [ ] **Step 6: Run the controller tests**

Run: `mix test test/alambic_web/controllers/annotate_cleaning_controller_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/alambic_web/controllers/annotate_cleaning_controller.ex lib/alambic_web/controllers/annotate_cleaning_html.ex lib/alambic_web/controllers/annotate_cleaning_html/done.html.heex lib/alambic_web/router.ex test/alambic_web/controllers/annotate_cleaning_controller_test.exs
git commit -m "feat(web): add /annotate-cleaning queue walker"
```

---

### Task 6: `EditCleaningLive` honors `?after=annotate`

When `EditCleaningLive` is mounted with `?after=annotate` and a save succeeds, `push_navigate` to `/annotate-cleaning` (which then redirects to the next pending item, or shows the all-done page).

**Files:**
- Modify: `lib/alambic_web/live/edit_cleaning_live.ex`
- Modify: `test/alambic_web/live/edit_cleaning_live_test.exs`

- [ ] **Step 1: Write a failing LiveView test**

Append to `test/alambic_web/live/edit_cleaning_live_test.exs` (inside the existing module). Use the existing test setup for fetching cleaning content — copy the surrounding pattern from a current test in the file if needed; the snippet below assumes the same Cham-stub setup as other tests:

```elixir
  describe "after=annotate redirect" do
    test "save with ?after=annotate push_navigates to /annotate-cleaning", %{conn: conn} do
      # Reuse whatever Cham content stubbing the other tests in this file use.
      # Pattern (mirror an existing test in this file):
      #   stub_cham_content("annot-flow", "hello world")
      stub_cham_content("annot-flow", "hello world")

      {:ok, view, _html} = live(conn, ~p"/edit-cleaning/annot-flow?after=annotate")

      assert {:error, {:live_redirect, %{to: "/annotate-cleaning"}}} =
               render_click(view, "save")
    end
  end
```

If the existing test file uses a different stubbing helper name, copy that helper's invocation pattern instead of `stub_cham_content/2` — the only requirement is that `Cham.fetch_cleaning_content("annot-flow")` returns `{:ok, "hello world"}` for the duration of the test.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/alambic_web/live/edit_cleaning_live_test.exs`
Expected: FAIL — save handler currently stays on the page; no redirect.

- [ ] **Step 3: Read `after` from the URL on mount**

In `lib/alambic_web/live/edit_cleaning_live.ex`, modify `mount/3` to also accept the `after` query parameter and stash it. The simplest place is the params map — but LiveView passes only path params to `mount/3`'s first arg. Use `handle_params/3` instead. Add this function after `mount/3`:

```elixir
  def handle_params(params, _uri, socket) do
    after_action =
      case Map.get(params, "after") do
        "annotate" -> :annotate
        _ -> nil
      end

    {:noreply, assign(socket, after_action: after_action)}
  end
```

Also initialize `after_action: nil` in both `assign(socket, ...)` calls inside `mount/3` so the assign always exists.

- [ ] **Step 4: Redirect on successful save when `after_action == :annotate`**

In the existing `handle_event("save", _, socket)`, change the success branch from:

```elixir
      {:ok, _row, status} ->
        :ok = ReviewQueue.resolve(item_id, :cleaning)
        flash = if status == :unchanged, do: "Saved — no changes.", else: "Saved."

        latest = Cleanings.latest(item_id)
        history = Cleanings.history(item_id)

        {:noreply,
         socket
         |> assign(latest: latest, history: history, drift?: false)
         |> put_flash(:info, flash)}
```

to:

```elixir
      {:ok, _row, status} ->
        :ok = ReviewQueue.resolve(item_id, :cleaning)
        flash = if status == :unchanged, do: "Saved — no changes.", else: "Saved."

        if socket.assigns.after_action == :annotate do
          {:noreply,
           socket
           |> put_flash(:info, flash)
           |> push_navigate(to: ~p"/annotate-cleaning")}
        else
          latest = Cleanings.latest(item_id)
          history = Cleanings.history(item_id)

          {:noreply,
           socket
           |> assign(latest: latest, history: history, drift?: false)
           |> put_flash(:info, flash)}
        end
```

- [ ] **Step 5: Run the LiveView tests**

Run: `mix test test/alambic_web/live/edit_cleaning_live_test.exs`
Expected: PASS, including the new redirect test.

- [ ] **Step 6: Run the full suite**

Run: `mix test`
Expected: PASS.

- [ ] **Step 7: Manual smoke check (recommended, not required to pass CI)**

In one terminal: `mix phx.server`. In a browser:
1. Enqueue a couple of cleaning-stage queue entries (via `iex -S mix phx.server` if no UI exists).
2. Visit `/annotate-cleaning`. Confirm redirect to `/edit-cleaning/:item_id?after=annotate`.
3. Make a span, click Save. Confirm redirect back to `/annotate-cleaning` and onward to the next item.
4. Annotate the last item; confirm the "All annotated" page renders.

- [ ] **Step 8: Commit**

```bash
git add lib/alambic_web/live/edit_cleaning_live.ex test/alambic_web/live/edit_cleaning_live_test.exs
git commit -m "feat(web): EditCleaningLive redirects to /annotate-cleaning when after=annotate"
```

---

## Self-Review Notes

- **Spec coverage**
  - `source` column on revisions with `human | model | llm_batch` → Tasks 1–3.
  - Backfill existing rows → Task 1 step 1 (migration `execute/2`).
  - `/annotate-cleaning` walks the review queue → Tasks 4–5.
  - One item at a time, advance on save → Task 6.
  - Skip items that already have a revision → Task 4 (`NOT EXISTS` subquery + test).
  - Use review-queue ordering → Task 4 (`asc: confidence, asc: queued_at`, mirroring `ReviewQueue.list_pending/0`).
  - No nav from queue page in v1; URL is just typed → Task 5 (route only, no link from `/queue`).

- **Open follow-ups (out of scope for v1)**
  - Bulk LLM labeling path (`source: "llm_batch"`) — the schema accepts it; no writer code yet.
  - Re-review mode that revisits items with revisions.
  - A link from `/queue` to `/annotate-cleaning`.
  - Setting `source: "model"` from the inference path (it doesn't persist revisions today; if/when it starts to, it must pass `source: "model"`).
