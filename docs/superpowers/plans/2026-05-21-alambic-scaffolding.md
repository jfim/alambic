# Alambic Scaffolding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the alambic Phoenix application end-to-end against the spec, with placeholder ML models (dummy `uv`-invoked Python scripts) and read-only Cham integration.

**Architecture:** Phoenix 1.7 / LiveView app. Four Ecto-backed contexts (`Models`, `Extractions`, `Cleanings`, `ReviewQueue`) sit behind an `Inference` facade. The facade returns saved results when present, otherwise invokes the active model's script via a Port-based `ScriptRunner` (mirroring `cham-v2`). Cham integration is HTTP read-only behind a `@behaviour`, mocked in tests. Correction LiveViews are placeholders that actually fetch HTML from Cham and write confirmation rows locally, without calling back to Cham.

**Tech Stack:** Elixir 1.19 / OTP 28, Phoenix 1.7, Ecto/Postgres, Bandit, Req (HTTP client), Mox (behaviour mocking), `uv` for Python scripts.

**Spec reference:** [`docs/superpowers/specs/2026-05-21-alambic-scaffolding-design.md`](../specs/2026-05-21-alambic-scaffolding-design.md)

---

## File map

```
mix.exs                                      # add :req, :mox deps
config/config.exs                            # default Cham impl + threshold + raw filename
config/test.exs                              # use Cham mock
config/runtime.exs                           # CHAM_BASE_URL, threshold, raw filename

priv/repo/migrations/*_create_models.exs
priv/repo/migrations/*_create_extractions.exs
priv/repo/migrations/*_create_cleanings.exs
priv/repo/migrations/*_create_review_queue.exs
priv/repo/seeds.exs                          # dummy model rows

lib/alambic/models.ex                        # context
lib/alambic/models/model.ex                  # schema
lib/alambic/extractions.ex                   # context
lib/alambic/extractions/extraction.ex        # schema
lib/alambic/cleanings.ex                     # context
lib/alambic/cleanings/cleaning.ex            # schema
lib/alambic/review_queue.ex                  # context
lib/alambic/review_queue/entry.ex            # schema
lib/alambic/script_runner.ex                 # Port-based uv runner
lib/alambic/cham.ex                          # behaviour + dispatcher
lib/alambic/cham/http.ex                     # Req-based impl
lib/alambic/inference.ex                     # extract/clean facade
lib/alambic/html_sanitizer.ex                # Floki-based pre-render scrubber

scripts/extract/main.py                      # dummy: prints {"xpath":"/","confidence":null}
scripts/clean/main.py                        # dummy: prints {"cleaned_text":"foo","confidence":null}

lib/alambic_web/router.ex                    # add routes
lib/alambic_web/controllers/extract_controller.ex
lib/alambic_web/controllers/extract_json.ex
lib/alambic_web/controllers/clean_controller.ex
lib/alambic_web/controllers/clean_json.ex
lib/alambic_web/controllers/admin/model_controller.ex
lib/alambic_web/controllers/admin/model_json.ex
lib/alambic_web/live/queue_live.ex
lib/alambic_web/live/edit_extraction_live.ex
lib/alambic_web/live/edit_cleaning_live.ex

test/test_helper.exs                         # Mox setup
test/alambic/models_test.exs
test/alambic/extractions_test.exs
test/alambic/cleanings_test.exs
test/alambic/review_queue_test.exs
test/alambic/script_runner_test.exs
test/alambic/cham/http_test.exs
test/alambic/inference_test.exs
test/alambic/html_sanitizer_test.exs
test/alambic_web/controllers/extract_controller_test.exs
test/alambic_web/controllers/clean_controller_test.exs
test/alambic_web/controllers/admin/model_controller_test.exs
test/alambic_web/live/queue_live_test.exs
test/alambic_web/live/edit_extraction_live_test.exs
test/alambic_web/live/edit_cleaning_live_test.exs

Dockerfile                                   # install uv, COPY scripts
docker-compose.yml                           # uv_cache volume
.env.example                                 # CHAM_BASE_URL
```

---

## Task 1: Add dependencies and base config

**Files:**
- Modify: `mix.exs`
- Modify: `config/config.exs`
- Modify: `config/test.exs`
- Modify: `config/runtime.exs`
- Modify: `test/test_helper.exs`

- [ ] **Step 1: Add `:req` and `:mox`; promote `:floki` to runtime**

Insert into the `deps/0` list in `mix.exs` (alongside the existing entries, before the closing `]`):

```elixir
      {:req, "~> 0.5"},
      {:mox, "~> 1.1", only: :test},
```

In the same `deps/0` list, find:

```elixir
      {:floki, ">= 0.30.0", only: :test},
```

and replace with:

```elixir
      {:floki, ">= 0.30.0"},
```

(Floki is needed at runtime for HTML sanitization in the correction LiveViews — see Task 13.)

- [ ] **Step 2: Fetch and compile**

Run:

```bash
cd ~/projects/alambic && mix deps.get && mix compile
```

Expected: dependencies resolve, project compiles without errors.

- [ ] **Step 3: Add base config keys to `config/config.exs`**

Append to `config/config.exs` (before `import_config`):

```elixir
config :alambic,
  cham_impl: Alambic.Cham.HTTP,
  cham_base_url: "http://localhost:4001",
  cham_raw_html_filename: "original.html",
  review_confidence_threshold: 0.7,
  scripts_path: "scripts"
```

- [ ] **Step 4: Override Cham impl in `config/test.exs`**

Append to `config/test.exs`:

```elixir
config :alambic, cham_impl: Alambic.ChamMock
```

- [ ] **Step 5: Wire env vars in `config/runtime.exs`**

In `config/runtime.exs`, inside the `if config_env() == :prod do` block, add:

```elixir
  config :alambic,
    cham_base_url: System.fetch_env!("ARCHIVE_BASE_URL"),
    review_confidence_threshold:
      "REVIEW_CONFIDENCE_THRESHOLD" |> System.get_env("0.7") |> String.to_float(),
    cham_raw_html_filename: System.get_env("CHAM_RAW_HTML_FILENAME", "original.html")
```

- [ ] **Step 6: Define the Mox mock in `test/test_helper.exs`**

Replace `test/test_helper.exs` contents with:

```elixir
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Alambic.Repo, :manual)
Mox.defmock(Alambic.ChamMock, for: Alambic.Cham)
```

(The behaviour `Alambic.Cham` is defined in Task 8. `Mox.defmock/2` is invoked at compile time of the test helper, but `Alambic.Cham` will exist by then because tests are compiled after `lib/`. If module-not-yet-defined causes issues in this commit, defer this single line to Task 8.)

- [ ] **Step 7: Commit**

```bash
cd ~/projects/alambic && git add -A && git commit -m "feat: add req+mox deps and base scaffolding config"
```

---

## Task 2: Models context (schema, migration, context, tests)

**Files:**
- Create: `priv/repo/migrations/20260521000001_create_models.exs`
- Create: `lib/alambic/models/model.ex`
- Create: `lib/alambic/models.ex`
- Create: `test/alambic/models_test.exs`

- [ ] **Step 1: Write the failing context test**

Create `test/alambic/models_test.exs`:

```elixir
defmodule Alambic.ModelsTest do
  use Alambic.DataCase, async: true

  alias Alambic.Models
  alias Alambic.Models.Model

  describe "list/0" do
    test "returns all registered models" do
      assert Models.list() == []
      {:ok, _} = insert_model(%{version: "v1", stage: :extraction, status: :active})
      assert [%Model{version: "v1"}] = Models.list()
    end
  end

  describe "active_for/1" do
    test "returns the active model for a stage, or nil" do
      assert Models.active_for(:extraction) == nil
      {:ok, _} = insert_model(%{version: "v1", stage: :extraction, status: :active})
      {:ok, _} = insert_model(%{version: "v2", stage: :extraction, status: :retired})
      assert %Model{version: "v1"} = Models.active_for(:extraction)
    end
  end

  describe "activate/1" do
    test "promotes a model and retires the previously active one in the same stage" do
      {:ok, old} = insert_model(%{version: "old", stage: :extraction, status: :active})
      {:ok, new} = insert_model(%{version: "new", stage: :extraction, status: :retired})

      {:ok, %Model{version: "new", status: :active}} = Models.activate("new")

      assert Alambic.Repo.get!(Model, old.version).status == :retired
      assert Alambic.Repo.get!(Model, new.version).status == :active
    end

    test "returns {:error, :not_found} for unknown versions" do
      assert Models.activate("nope") == {:error, :not_found}
    end
  end

  defp insert_model(attrs) do
    defaults = %{
      trained_at: DateTime.utc_now() |> DateTime.truncate(:second),
      artifact_path: "scripts/extract",
      training_sample_size: 0
    }

    %Model{}
    |> Model.changeset(Map.merge(defaults, attrs))
    |> Alambic.Repo.insert()
  end
end
```

- [ ] **Step 2: Run the test, expect compile failure**

Run:

```bash
cd ~/projects/alambic && mix test test/alambic/models_test.exs 2>&1 | tail -10
```

Expected: compile error — `Alambic.Models.Model` and/or `Alambic.Models` not defined.

- [ ] **Step 3: Create the migration**

Create `priv/repo/migrations/20260521000001_create_models.exs`:

```elixir
defmodule Alambic.Repo.Migrations.CreateModels do
  use Ecto.Migration

  def change do
    create table(:models, primary_key: false) do
      add :version, :string, primary_key: true
      add :stage, :string, null: false
      add :trained_at, :utc_datetime, null: false
      add :artifact_path, :string, null: false
      add :training_sample_size, :integer, null: false, default: 0
      add :status, :string, null: false
    end

    create index(:models, [:stage])

    create unique_index(:models, [:stage],
             where: "status = 'active'",
             name: :one_active_model_per_stage)
  end
end
```

- [ ] **Step 4: Create the schema**

Create `lib/alambic/models/model.ex`:

```elixir
defmodule Alambic.Models.Model do
  use Ecto.Schema
  import Ecto.Changeset

  @stages [:extraction, :cleaning]
  @statuses [:active, :retired, :failed]

  @primary_key {:version, :string, autogenerate: false}
  schema "models" do
    field :stage, Ecto.Enum, values: @stages
    field :trained_at, :utc_datetime
    field :artifact_path, :string
    field :training_sample_size, :integer, default: 0
    field :status, Ecto.Enum, values: @statuses
  end

  def changeset(model, attrs) do
    model
    |> cast(attrs, [:version, :stage, :trained_at, :artifact_path, :training_sample_size, :status])
    |> validate_required([:version, :stage, :trained_at, :artifact_path, :status])
  end

  def stages, do: @stages
end
```

- [ ] **Step 5: Create the context**

Create `lib/alambic/models.ex`:

```elixir
defmodule Alambic.Models do
  import Ecto.Query

  alias Alambic.Models.Model
  alias Alambic.Repo

  def list, do: Repo.all(from m in Model, order_by: [asc: m.stage, asc: m.version])

  def active_for(stage) when stage in [:extraction, :cleaning] do
    Repo.one(from m in Model, where: m.stage == ^stage and m.status == :active)
  end

  def activate(version) when is_binary(version) do
    case Repo.get(Model, version) do
      nil ->
        {:error, :not_found}

      %Model{stage: stage} = model ->
        Repo.transaction(fn ->
          Repo.update_all(
            from(m in Model, where: m.stage == ^stage and m.status == :active),
            set: [status: :retired]
          )

          {:ok, updated} = model |> Model.changeset(%{status: :active}) |> Repo.update()
          updated
        end)
    end
  end
end
```

- [ ] **Step 6: Run migration and test**

Run:

```bash
cd ~/projects/alambic && mix ecto.create && mix ecto.migrate && mix test test/alambic/models_test.exs
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
cd ~/projects/alambic && git add -A && git commit -m "feat: models schema and registry context"
```

---

## Task 3: Extractions context

**Files:**
- Create: `priv/repo/migrations/20260521000002_create_extractions.exs`
- Create: `lib/alambic/extractions/extraction.ex`
- Create: `lib/alambic/extractions.ex`
- Create: `test/alambic/extractions_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/alambic/extractions_test.exs`:

```elixir
defmodule Alambic.ExtractionsTest do
  use Alambic.DataCase, async: true

  alias Alambic.Extractions
  alias Alambic.Extractions.Extraction

  test "get/1 returns nil for unknown item_id" do
    assert Extractions.get("nope") == nil
  end

  test "save/1 upserts an extraction row" do
    attrs = %{
      item_id: "abc",
      xpath: "/html/body/article",
      html_snapshot: "<html>...</html>",
      model_version: "v1"
    }

    {:ok, %Extraction{item_id: "abc"}} = Extractions.save(attrs)
    assert %Extraction{xpath: "/html/body/article"} = Extractions.get("abc")

    {:ok, _} = Extractions.save(%{attrs | xpath: "/html/body/main"})
    assert %Extraction{xpath: "/html/body/main"} = Extractions.get("abc")
  end
end
```

- [ ] **Step 2: Run and verify failure**

```bash
cd ~/projects/alambic && mix test test/alambic/extractions_test.exs 2>&1 | tail -5
```

Expected: compile error.

- [ ] **Step 3: Create migration**

Create `priv/repo/migrations/20260521000002_create_extractions.exs`:

```elixir
defmodule Alambic.Repo.Migrations.CreateExtractions do
  use Ecto.Migration

  def change do
    create table(:extractions, primary_key: false) do
      add :item_id, :string, primary_key: true
      add :xpath, :string, null: false
      add :html_snapshot, :text, null: false
      add :confirmed_at, :utc_datetime, null: false
      add :model_version, :string
    end
  end
end
```

- [ ] **Step 4: Create schema**

Create `lib/alambic/extractions/extraction.ex`:

```elixir
defmodule Alambic.Extractions.Extraction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:item_id, :string, autogenerate: false}
  schema "extractions" do
    field :xpath, :string
    field :html_snapshot, :string
    field :confirmed_at, :utc_datetime
    field :model_version, :string
  end

  def changeset(extraction, attrs) do
    attrs =
      Map.put_new_lazy(attrs, :confirmed_at, fn ->
        DateTime.utc_now() |> DateTime.truncate(:second)
      end)

    extraction
    |> cast(attrs, [:item_id, :xpath, :html_snapshot, :confirmed_at, :model_version])
    |> validate_required([:item_id, :xpath, :html_snapshot, :confirmed_at])
  end
end
```

- [ ] **Step 5: Create context**

Create `lib/alambic/extractions.ex`:

```elixir
defmodule Alambic.Extractions do
  alias Alambic.Extractions.Extraction
  alias Alambic.Repo

  def get(item_id), do: Repo.get(Extraction, item_id)

  def save(attrs) do
    case Repo.get(Extraction, attrs.item_id) do
      nil -> %Extraction{}
      existing -> existing
    end
    |> Extraction.changeset(attrs)
    |> Repo.insert_or_update()
  end
end
```

- [ ] **Step 6: Migrate and test**

```bash
cd ~/projects/alambic && mix ecto.migrate && mix test test/alambic/extractions_test.exs
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
cd ~/projects/alambic && git add -A && git commit -m "feat: extractions schema and context"
```

---

## Task 4: Cleanings context

**Files:**
- Create: `priv/repo/migrations/20260521000003_create_cleanings.exs`
- Create: `lib/alambic/cleanings/cleaning.ex`
- Create: `lib/alambic/cleanings.ex`
- Create: `test/alambic/cleanings_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/alambic/cleanings_test.exs`:

```elixir
defmodule Alambic.CleaningsTest do
  use Alambic.DataCase, async: true

  alias Alambic.Cleanings
  alias Alambic.Cleanings.Cleaning

  test "get/1 returns nil for unknown item_id" do
    assert Cleanings.get("nope") == nil
  end

  test "save/1 upserts a cleaning row" do
    attrs = %{
      item_id: "abc",
      token_labels: [%{"token" => "hi", "label" => "keep"}],
      source_text: "hi world",
      model_version: "v1"
    }

    {:ok, %Cleaning{item_id: "abc"}} = Cleanings.save(attrs)
    assert %Cleaning{source_text: "hi world"} = Cleanings.get("abc")

    {:ok, _} = Cleanings.save(%{attrs | source_text: "hi mars"})
    assert %Cleaning{source_text: "hi mars"} = Cleanings.get("abc")
  end
end
```

- [ ] **Step 2: Verify it fails**

```bash
cd ~/projects/alambic && mix test test/alambic/cleanings_test.exs 2>&1 | tail -5
```

Expected: compile error.

- [ ] **Step 3: Create migration**

Create `priv/repo/migrations/20260521000003_create_cleanings.exs`:

```elixir
defmodule Alambic.Repo.Migrations.CreateCleanings do
  use Ecto.Migration

  def change do
    create table(:cleanings, primary_key: false) do
      add :item_id, :string, primary_key: true
      add :token_labels, :jsonb, null: false
      add :source_text, :text, null: false
      add :confirmed_at, :utc_datetime, null: false
      add :model_version, :string
    end
  end
end
```

- [ ] **Step 4: Create schema**

Create `lib/alambic/cleanings/cleaning.ex`:

```elixir
defmodule Alambic.Cleanings.Cleaning do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:item_id, :string, autogenerate: false}
  schema "cleanings" do
    field :token_labels, {:array, :map}
    field :source_text, :string
    field :confirmed_at, :utc_datetime
    field :model_version, :string
  end

  def changeset(cleaning, attrs) do
    attrs =
      Map.put_new_lazy(attrs, :confirmed_at, fn ->
        DateTime.utc_now() |> DateTime.truncate(:second)
      end)

    cleaning
    |> cast(attrs, [:item_id, :token_labels, :source_text, :confirmed_at, :model_version])
    |> validate_required([:item_id, :token_labels, :source_text, :confirmed_at])
  end
end
```

- [ ] **Step 5: Create context**

Create `lib/alambic/cleanings.ex`:

```elixir
defmodule Alambic.Cleanings do
  alias Alambic.Cleanings.Cleaning
  alias Alambic.Repo

  def get(item_id), do: Repo.get(Cleaning, item_id)

  def save(attrs) do
    case Repo.get(Cleaning, attrs.item_id) do
      nil -> %Cleaning{}
      existing -> existing
    end
    |> Cleaning.changeset(attrs)
    |> Repo.insert_or_update()
  end
end
```

- [ ] **Step 6: Migrate and test**

```bash
cd ~/projects/alambic && mix ecto.migrate && mix test test/alambic/cleanings_test.exs
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
cd ~/projects/alambic && git add -A && git commit -m "feat: cleanings schema and context"
```

---

## Task 5: ReviewQueue context

**Files:**
- Create: `priv/repo/migrations/20260521000004_create_review_queue.exs`
- Create: `lib/alambic/review_queue/entry.ex`
- Create: `lib/alambic/review_queue.ex`
- Create: `test/alambic/review_queue_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/alambic/review_queue_test.exs`:

```elixir
defmodule Alambic.ReviewQueueTest do
  use Alambic.DataCase, async: true

  alias Alambic.ReviewQueue
  alias Alambic.ReviewQueue.Entry

  test "enqueue/1 inserts a pending row; resolve/2 sets resolved_at" do
    attrs = %{item_id: "abc", stage: :extraction, confidence: 0.4, model_version: "v1"}
    {:ok, %Entry{resolved_at: nil}} = ReviewQueue.enqueue(attrs)

    assert [%Entry{item_id: "abc"}] = ReviewQueue.list_pending()

    :ok = ReviewQueue.resolve("abc", :extraction)
    assert ReviewQueue.list_pending() == []
  end

  test "list_pending/0 orders by ascending confidence" do
    for {id, c} <- [{"a", 0.9}, {"b", 0.1}, {"c", 0.5}] do
      {:ok, _} =
        ReviewQueue.enqueue(%{item_id: id, stage: :extraction, confidence: c, model_version: "v1"})
    end

    assert ["b", "c", "a"] = Enum.map(ReviewQueue.list_pending(), & &1.item_id)
  end

  test "enqueue/1 is idempotent on (item_id, stage)" do
    attrs = %{item_id: "x", stage: :extraction, confidence: 0.3, model_version: "v1"}
    {:ok, _} = ReviewQueue.enqueue(attrs)
    {:ok, _} = ReviewQueue.enqueue(%{attrs | confidence: 0.5})
    assert [%Entry{confidence: 0.5}] = ReviewQueue.list_pending()
  end
end
```

- [ ] **Step 2: Verify it fails**

```bash
cd ~/projects/alambic && mix test test/alambic/review_queue_test.exs 2>&1 | tail -5
```

Expected: compile error.

- [ ] **Step 3: Create migration**

Create `priv/repo/migrations/20260521000004_create_review_queue.exs`:

```elixir
defmodule Alambic.Repo.Migrations.CreateReviewQueue do
  use Ecto.Migration

  def change do
    create table(:review_queue, primary_key: false) do
      add :item_id, :string, primary_key: true, null: false
      add :stage, :string, primary_key: true, null: false
      add :confidence, :float, null: false
      add :model_version, :string, null: false
      add :queued_at, :utc_datetime, null: false
      add :resolved_at, :utc_datetime
    end

    create index(:review_queue, [:resolved_at, :confidence])
  end
end
```

- [ ] **Step 4: Create schema**

Create `lib/alambic/review_queue/entry.ex`:

```elixir
defmodule Alambic.ReviewQueue.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  @stages [:extraction, :cleaning]

  @primary_key false
  schema "review_queue" do
    field :item_id, :string, primary_key: true
    field :stage, Ecto.Enum, values: @stages, primary_key: true
    field :confidence, :float
    field :model_version, :string
    field :queued_at, :utc_datetime
    field :resolved_at, :utc_datetime
  end

  def changeset(entry, attrs) do
    attrs =
      Map.put_new_lazy(attrs, :queued_at, fn ->
        DateTime.utc_now() |> DateTime.truncate(:second)
      end)

    entry
    |> cast(attrs, [:item_id, :stage, :confidence, :model_version, :queued_at, :resolved_at])
    |> validate_required([:item_id, :stage, :confidence, :model_version, :queued_at])
  end
end
```

- [ ] **Step 5: Create context**

Create `lib/alambic/review_queue.ex`:

```elixir
defmodule Alambic.ReviewQueue do
  import Ecto.Query

  alias Alambic.Repo
  alias Alambic.ReviewQueue.Entry

  def enqueue(attrs) do
    %Entry{}
    |> Entry.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:confidence, :model_version, :queued_at, :resolved_at]},
      conflict_target: [:item_id, :stage]
    )
  end

  def resolve(item_id, stage) when stage in [:extraction, :cleaning] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {_, _} =
      Repo.update_all(
        from(e in Entry,
          where: e.item_id == ^item_id and e.stage == ^stage and is_nil(e.resolved_at)
        ),
        set: [resolved_at: now]
      )

    :ok
  end

  def list_pending do
    Repo.all(
      from e in Entry,
        where: is_nil(e.resolved_at),
        order_by: [asc: e.confidence, asc: e.queued_at]
    )
  end
end
```

- [ ] **Step 6: Migrate and test**

```bash
cd ~/projects/alambic && mix ecto.migrate && mix test test/alambic/review_queue_test.exs
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
cd ~/projects/alambic && git add -A && git commit -m "feat: review_queue schema and context"
```

---

## Task 6: ScriptRunner module

**Files:**
- Create: `lib/alambic/script_runner.ex`
- Create: `test/alambic/script_runner_test.exs`
- Create: `test/support/fixtures/echo.py` (test fixture)

- [ ] **Step 1: Write a fixture Python script for the test**

Create `test/support/fixtures/echo.py`:

```python
# /// script
# requires-python = ">=3.11"
# ///
import json, sys
payload = {"echoed": sys.argv[1] if len(sys.argv) > 1 else None}
print(json.dumps(payload))
```

- [ ] **Step 2: Write the failing test**

Create `test/alambic/script_runner_test.exs`:

```elixir
defmodule Alambic.ScriptRunnerTest do
  use ExUnit.Case, async: true

  alias Alambic.ScriptRunner

  @fixture_path "test/support/fixtures/echo.py"

  test "run_sync/3 returns stdout and exit code for a successful script" do
    assert {:ok, output, 0} = ScriptRunner.run_sync("uv", ["run", @fixture_path, "hello"], timeout: 60_000)
    assert %{"echoed" => "hello"} = Jason.decode!(String.trim(output))
  end

  test "run_sync/3 reports timeout when the script exceeds the limit" do
    sleeper = """
    # /// script
    # requires-python = ">=3.11"
    # ///
    import time; time.sleep(5)
    """

    path = Path.join(System.tmp_dir!(), "sleeper_#{System.unique_integer([:positive])}.py")
    File.write!(path, sleeper)
    on_exit(fn -> File.rm(path) end)

    assert {:error, :timeout, _, _} = ScriptRunner.run_sync("uv", ["run", path], timeout: 100)
  end
end
```

- [ ] **Step 3: Verify it fails**

```bash
cd ~/projects/alambic && mix test test/alambic/script_runner_test.exs 2>&1 | tail -5
```

Expected: `Alambic.ScriptRunner` not defined.

- [ ] **Step 4: Implement ScriptRunner**

Create `lib/alambic/script_runner.ex`:

```elixir
defmodule Alambic.ScriptRunner do
  @moduledoc """
  Spawns external commands via Port and collects stdout (with stderr merged in).
  Mirrors the cham-v2 ScriptRunner so future scripts share a convention.
  """

  def run_sync(command, args, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    executable = System.find_executable(command) || raise "executable not found: #{command}"

    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, :stderr_to_stdout, args: args]
      )

    case collect_output(port, timeout, []) do
      {:ok, output, exit_code} ->
        {:ok, output, exit_code}

      {:error, :timeout, output} ->
        kill_port(port)
        {:error, :timeout, output, ""}
    end
  end

  def run_script_sync(script_dir, args, opts) do
    scripts_path = Keyword.get(opts, :scripts_path, Application.get_env(:alambic, :scripts_path))
    clean_opts = Keyword.drop(opts, [:scripts_path])
    script_path = Path.join([scripts_path, script_dir, "main.py"])
    run_sync("uv", ["run", script_path | args], clean_opts)
  end

  defp collect_output(port, timeout, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, timeout, [data | acc])

      {^port, {:exit_status, exit_code}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, output, exit_code}
    after
      timeout ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, :timeout, output}
    end
  end

  defp kill_port(port) do
    try do
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      Port.close(port)
      System.cmd("kill", ["-9", "#{os_pid}"])
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end
end
```

- [ ] **Step 5: Run tests**

```bash
cd ~/projects/alambic && mix test test/alambic/script_runner_test.exs
```

Expected: pass. (Requires `uv` installed locally; if not, skip these tests with a tag — but they should be green on dev hosts.)

- [ ] **Step 6: Commit**

```bash
cd ~/projects/alambic && git add -A && git commit -m "feat: Port-based ScriptRunner mirroring cham-v2"
```

---

## Task 7: Dummy Python scripts

**Files:**
- Create: `scripts/extract/main.py`
- Create: `scripts/clean/main.py`

- [ ] **Step 1: Create the extract dummy**

Create `scripts/extract/main.py`:

```python
# /// script
# requires-python = ">=3.11"
# ///
"""Dummy extraction model.

Receives an HTML file path on argv[1] (ignored). Emits a stub XPath result
on stdout as JSON. Replaced by a real model later without changes on the
Elixir side as long as the output schema is preserved.
"""
import json
import sys

_ = sys.argv[1:]  # input path ignored by the dummy
print(json.dumps({"xpath": "/", "confidence": None}))
```

- [ ] **Step 2: Create the clean dummy**

Create `scripts/clean/main.py`:

```python
# /// script
# requires-python = ">=3.11"
# ///
"""Dummy cleaning model.

Receives an extracted-text file path on argv[1] (ignored). Emits a stub
cleaned-text result on stdout as JSON.
"""
import json
import sys

_ = sys.argv[1:]
print(json.dumps({"cleaned_text": "foo", "confidence": None}))
```

- [ ] **Step 3: Smoke-test both scripts manually**

```bash
cd ~/projects/alambic && uv run scripts/extract/main.py /dev/null && uv run scripts/clean/main.py /dev/null
```

Expected output:

```
{"xpath": "/", "confidence": null}
{"cleaned_text": "foo", "confidence": null}
```

- [ ] **Step 4: Commit**

```bash
cd ~/projects/alambic && git add -A && git commit -m "feat: dummy uv scripts for extract and clean"
```

---

## Task 8: Cham client (behaviour + HTTP impl)

**Files:**
- Create: `lib/alambic/cham.ex`
- Create: `lib/alambic/cham/http.ex`
- Create: `test/alambic/cham/http_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/alambic/cham/http_test.exs`:

```elixir
defmodule Alambic.Cham.HTTPTest do
  use ExUnit.Case, async: true

  alias Alambic.Cham.HTTP

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  test "fetch_html/1 hits /api/v1/items/:id/files/:filename and returns the body",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "GET", "/api/v1/items/abc/files/original.html", fn conn ->
      Plug.Conn.resp(conn, 200, "<html>hi</html>")
    end)

    assert {:ok, "<html>hi</html>"} =
             HTTP.fetch_html("abc", base_url: base_url, filename: "original.html")
  end

  test "fetch_html/1 returns {:error, :not_found} on 404",
       %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "GET", "/api/v1/items/abc/files/original.html", fn conn ->
      Plug.Conn.resp(conn, 404, "")
    end)

    assert {:error, {:status, 404}} =
             HTTP.fetch_html("abc", base_url: base_url, filename: "original.html")
  end
end
```

- [ ] **Step 2: Add `:bypass` dep**

In `mix.exs`, add to deps:

```elixir
      {:bypass, "~> 2.1", only: :test},
```

Then run:

```bash
cd ~/projects/alambic && mix deps.get
```

- [ ] **Step 3: Verify the test fails (no module yet)**

```bash
cd ~/projects/alambic && mix test test/alambic/cham/http_test.exs 2>&1 | tail -5
```

Expected: compile error.

- [ ] **Step 4: Define the behaviour and dispatcher**

Create `lib/alambic/cham.ex`:

```elixir
defmodule Alambic.Cham do
  @moduledoc "Read-only client for the Cham archive API."

  @callback fetch_html(item_id :: String.t()) :: {:ok, binary} | {:error, term}

  def fetch_html(item_id), do: impl().fetch_html(item_id)

  defp impl, do: Application.fetch_env!(:alambic, :cham_impl)
end
```

- [ ] **Step 5: Implement the HTTP client**

Create `lib/alambic/cham/http.ex`:

```elixir
defmodule Alambic.Cham.HTTP do
  @behaviour Alambic.Cham

  @impl Alambic.Cham
  def fetch_html(item_id) do
    fetch_html(item_id,
      base_url: Application.fetch_env!(:alambic, :cham_base_url),
      filename: Application.fetch_env!(:alambic, :cham_raw_html_filename)
    )
  end

  @doc false
  def fetch_html(item_id, opts) do
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

- [ ] **Step 6: Run test**

```bash
cd ~/projects/alambic && mix test test/alambic/cham/http_test.exs
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
cd ~/projects/alambic && git add -A && git commit -m "feat: read-only Cham HTTP client with behaviour"
```

---

## Task 9: Inference facade

**Files:**
- Create: `lib/alambic/inference.ex`
- Create: `test/alambic/inference_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/alambic/inference_test.exs`:

```elixir
defmodule Alambic.InferenceTest do
  use Alambic.DataCase, async: true

  alias Alambic.Extractions
  alias Alambic.Inference
  alias Alambic.Models.Model
  alias Alambic.ReviewQueue
  alias Alambic.Repo

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
    {:ok, _} = Extractions.save(%{item_id: "x", xpath: "/saved", html_snapshot: "<h/>"})

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

  test "clean/2 returns saved row when present" do
    {:ok, _} =
      Alambic.Cleanings.save(%{
        item_id: "x",
        token_labels: [%{"token" => "hi", "label" => "keep"}],
        source_text: "hi"
      })

    assert {:ok, %{item_id: "x", source: :saved, cleaned_text: "hi"}} = Inference.clean("x", "hi")
  end

  test "clean/2 invokes active cleaning script when no saved row" do
    seed_active_model(:cleaning, "cleaning-dummy.1", "scripts/clean")
    assert {:ok, %{cleaned_text: "foo", source: :model}} = Inference.clean("x", "ignored")
  end
end
```

- [ ] **Step 2: Create the fixture for the low-confidence test**

Create `test/support/fixtures/low_confidence_extract/main.py`:

```python
# /// script
# requires-python = ">=3.11"
# ///
import json, sys
_ = sys.argv[1:]
print(json.dumps({"xpath": "/", "confidence": 0.2}))
```

- [ ] **Step 3: Verify failure**

```bash
cd ~/projects/alambic && mix test test/alambic/inference_test.exs 2>&1 | tail -10
```

Expected: `Alambic.Inference` not defined.

- [ ] **Step 4: Implement Inference**

Create `lib/alambic/inference.ex`:

```elixir
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
    case Cleanings.get(item_id) do
      %{source_text: source_text} ->
        {:ok,
         %{
           item_id: item_id,
           cleaned_text: source_text,
           source: :saved,
           model_version: nil,
           confidence: nil
         }}

      nil ->
        run_model(:cleaning, item_id, text, &decode_clean/1)
    end
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
              response = decoder.(payload) |> Map.merge(%{item_id: item_id, source: :model, model_version: version})
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
```

- [ ] **Step 5: Run tests**

```bash
cd ~/projects/alambic && mix test test/alambic/inference_test.exs
```

Expected: all six pass.

- [ ] **Step 6: Commit**

```bash
cd ~/projects/alambic && git add -A && git commit -m "feat: Inference facade with saved/model branching and queue enqueue"
```

---

## Task 10: ExtractController + CleanController + routes

**Files:**
- Modify: `lib/alambic_web/router.ex`
- Create: `lib/alambic_web/controllers/extract_controller.ex`
- Create: `lib/alambic_web/controllers/extract_json.ex`
- Create: `lib/alambic_web/controllers/clean_controller.ex`
- Create: `lib/alambic_web/controllers/clean_json.ex`
- Create: `test/alambic_web/controllers/extract_controller_test.exs`
- Create: `test/alambic_web/controllers/clean_controller_test.exs`

- [ ] **Step 1: Write failing controller tests**

Create `test/alambic_web/controllers/extract_controller_test.exs`:

```elixir
defmodule AlambicWeb.ExtractControllerTest do
  use AlambicWeb.ConnCase, async: true

  alias Alambic.Models.Model
  alias Alambic.Repo

  defp seed_active(stage, version, path) do
    {:ok, m} =
      %Model{}
      |> Model.changeset(%{
        version: version,
        stage: stage,
        trained_at: DateTime.utc_now() |> DateTime.truncate(:second),
        artifact_path: path,
        status: :active
      })
      |> Repo.insert()

    m
  end

  test "POST /api/extract returns 503 when no active model and no saved row", %{conn: conn} do
    conn = post(conn, ~p"/api/extract", %{"item_id" => "x", "html" => "<html/>"})
    assert json_response(conn, 503) == %{"error" => "no model available"}
  end

  test "POST /api/extract returns the model's prediction", %{conn: conn} do
    seed_active(:extraction, "extraction-dummy.1", "scripts/extract")

    conn = post(conn, ~p"/api/extract", %{"item_id" => "x", "html" => "<html/>"})

    assert %{
             "item_id" => "x",
             "xpath" => "/",
             "source" => "model",
             "model_version" => "extraction-dummy.1",
             "confidence" => nil
           } = json_response(conn, 200)
  end

  test "POST /api/extract returns 422 on missing fields", %{conn: conn} do
    conn = post(conn, ~p"/api/extract", %{})
    assert json_response(conn, 422)
  end
end
```

Create `test/alambic_web/controllers/clean_controller_test.exs`:

```elixir
defmodule AlambicWeb.CleanControllerTest do
  use AlambicWeb.ConnCase, async: true

  alias Alambic.Models.Model
  alias Alambic.Repo

  defp seed_active(stage, version, path) do
    {:ok, m} =
      %Model{}
      |> Model.changeset(%{
        version: version,
        stage: stage,
        trained_at: DateTime.utc_now() |> DateTime.truncate(:second),
        artifact_path: path,
        status: :active
      })
      |> Repo.insert()

    m
  end

  test "POST /api/clean returns 503 when no active model and no saved row", %{conn: conn} do
    conn = post(conn, ~p"/api/clean", %{"item_id" => "x", "text" => "hi"})
    assert json_response(conn, 503) == %{"error" => "no model available"}
  end

  test "POST /api/clean returns model output when active model is present", %{conn: conn} do
    seed_active(:cleaning, "cleaning-dummy.1", "scripts/clean")
    conn = post(conn, ~p"/api/clean", %{"item_id" => "x", "text" => "hi"})

    assert %{
             "item_id" => "x",
             "cleaned_text" => "foo",
             "source" => "model",
             "model_version" => "cleaning-dummy.1"
           } = json_response(conn, 200)
  end

  test "POST /api/clean returns 422 on missing fields", %{conn: conn} do
    conn = post(conn, ~p"/api/clean", %{})
    assert json_response(conn, 422)
  end
end
```

- [ ] **Step 2: Verify they fail**

```bash
cd ~/projects/alambic && mix test test/alambic_web/controllers/ 2>&1 | tail -10
```

Expected: route not found / module not defined.

- [ ] **Step 3: Add the routes**

In `lib/alambic_web/router.ex`, replace the commented `# scope "/api"...` block with:

```elixir
  scope "/api", AlambicWeb do
    pipe_through :api

    post "/extract", ExtractController, :create
    post "/clean", CleanController, :create
  end
```

- [ ] **Step 4: Implement ExtractController + JSON view**

Create `lib/alambic_web/controllers/extract_controller.ex`:

```elixir
defmodule AlambicWeb.ExtractController do
  use AlambicWeb, :controller

  alias Alambic.Inference

  def create(conn, %{"item_id" => item_id, "html" => html})
      when is_binary(item_id) and is_binary(html) do
    case Inference.extract(item_id, html) do
      {:ok, response} ->
        render(conn, :show, response: response)

      {:error, :no_model} ->
        conn |> put_status(503) |> json(%{error: "no model available"})

      {:error, _reason} ->
        conn |> put_status(500) |> json(%{error: "inference failed"})
    end
  end

  def create(conn, _) do
    conn |> put_status(422) |> json(%{error: "missing required fields: item_id, html"})
  end
end
```

Create `lib/alambic_web/controllers/extract_json.ex`:

```elixir
defmodule AlambicWeb.ExtractJSON do
  def show(%{response: r}) do
    %{
      item_id: r.item_id,
      xpath: r.xpath,
      source: r.source,
      model_version: r.model_version,
      confidence: r.confidence
    }
  end
end
```

- [ ] **Step 5: Implement CleanController + JSON view**

Create `lib/alambic_web/controllers/clean_controller.ex`:

```elixir
defmodule AlambicWeb.CleanController do
  use AlambicWeb, :controller

  alias Alambic.Inference

  def create(conn, %{"item_id" => item_id, "text" => text})
      when is_binary(item_id) and is_binary(text) do
    case Inference.clean(item_id, text) do
      {:ok, response} ->
        render(conn, :show, response: response)

      {:error, :no_model} ->
        conn |> put_status(503) |> json(%{error: "no model available"})

      {:error, _reason} ->
        conn |> put_status(500) |> json(%{error: "inference failed"})
    end
  end

  def create(conn, _) do
    conn |> put_status(422) |> json(%{error: "missing required fields: item_id, text"})
  end
end
```

Create `lib/alambic_web/controllers/clean_json.ex`:

```elixir
defmodule AlambicWeb.CleanJSON do
  def show(%{response: r}) do
    %{
      item_id: r.item_id,
      cleaned_text: r.cleaned_text,
      source: r.source,
      model_version: r.model_version,
      confidence: r.confidence
    }
  end
end
```

- [ ] **Step 6: Run tests**

```bash
cd ~/projects/alambic && mix test test/alambic_web/controllers/extract_controller_test.exs test/alambic_web/controllers/clean_controller_test.exs
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
cd ~/projects/alambic && git add -A && git commit -m "feat: /api/extract and /api/clean endpoints"
```

---

## Task 11: Admin model controller

**Files:**
- Modify: `lib/alambic_web/router.ex`
- Create: `lib/alambic_web/controllers/admin/model_controller.ex`
- Create: `lib/alambic_web/controllers/admin/model_json.ex`
- Create: `test/alambic_web/controllers/admin/model_controller_test.exs`

- [ ] **Step 1: Failing test**

Create `test/alambic_web/controllers/admin/model_controller_test.exs`:

```elixir
defmodule AlambicWeb.Admin.ModelControllerTest do
  use AlambicWeb.ConnCase, async: true

  alias Alambic.Models.Model
  alias Alambic.Repo

  defp insert(attrs) do
    %Model{}
    |> Model.changeset(
      Map.merge(
        %{
          trained_at: DateTime.utc_now() |> DateTime.truncate(:second),
          artifact_path: "scripts/extract",
          status: :retired
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  test "GET /api/models lists models", %{conn: conn} do
    insert(%{version: "v1", stage: :extraction, status: :active})
    insert(%{version: "v2", stage: :cleaning, status: :retired})

    conn = get(conn, ~p"/api/models")
    body = json_response(conn, 200)
    assert length(body) == 2
    assert Enum.find(body, &(&1["version"] == "v1"))["status"] == "active"
  end

  test "POST /api/models/:version/activate promotes it", %{conn: conn} do
    insert(%{version: "v1", stage: :extraction, status: :active})
    insert(%{version: "v2", stage: :extraction, status: :retired})

    conn = post(conn, ~p"/api/models/v2/activate")

    assert %{"version" => "v2", "status" => "active"} = json_response(conn, 200)
    assert Repo.get!(Model, "v1").status == :retired
  end

  test "POST /api/models/:version/activate returns 404 for unknown version", %{conn: conn} do
    conn = post(conn, ~p"/api/models/missing/activate")
    assert json_response(conn, 404)
  end
end
```

- [ ] **Step 2: Verify failure**

```bash
cd ~/projects/alambic && mix test test/alambic_web/controllers/admin/ 2>&1 | tail -5
```

- [ ] **Step 3: Add routes**

In `lib/alambic_web/router.ex`, extend the `/api` scope to:

```elixir
  scope "/api", AlambicWeb do
    pipe_through :api

    post "/extract", ExtractController, :create
    post "/clean", CleanController, :create

    get "/models", Admin.ModelController, :index
    post "/models/:version/activate", Admin.ModelController, :activate
  end
```

- [ ] **Step 4: Implement controller**

Create `lib/alambic_web/controllers/admin/model_controller.ex`:

```elixir
defmodule AlambicWeb.Admin.ModelController do
  use AlambicWeb, :controller

  alias Alambic.Models

  def index(conn, _params) do
    render(conn, :index, models: Models.list())
  end

  def activate(conn, %{"version" => version}) do
    case Models.activate(version) do
      {:ok, model} -> render(conn, :show, model: model)
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "model not found"})
    end
  end
end
```

Create `lib/alambic_web/controllers/admin/model_json.ex`:

```elixir
defmodule AlambicWeb.Admin.ModelJSON do
  alias Alambic.Models.Model

  def index(%{models: models}), do: Enum.map(models, &row/1)
  def show(%{model: model}), do: row(model)

  defp row(%Model{} = m) do
    %{
      version: m.version,
      stage: m.stage,
      status: m.status,
      trained_at: m.trained_at,
      artifact_path: m.artifact_path,
      training_sample_size: m.training_sample_size
    }
  end
end
```

- [ ] **Step 5: Run tests**

```bash
cd ~/projects/alambic && mix test test/alambic_web/controllers/admin/
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
cd ~/projects/alambic && git add -A && git commit -m "feat: admin model controller (list + activate)"
```

---

## Task 12: QueueLive

**Files:**
- Modify: `lib/alambic_web/router.ex`
- Create: `lib/alambic_web/live/queue_live.ex`
- Create: `test/alambic_web/live/queue_live_test.exs`

- [ ] **Step 1: Failing test**

Create `test/alambic_web/live/queue_live_test.exs`:

```elixir
defmodule AlambicWeb.QueueLiveTest do
  use AlambicWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Alambic.ReviewQueue

  test "renders empty queue message", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/queue")
    assert html =~ "Review queue is empty"
  end

  test "lists pending items in ascending confidence order with links", %{conn: conn} do
    {:ok, _} =
      ReviewQueue.enqueue(%{
        item_id: "a",
        stage: :extraction,
        confidence: 0.4,
        model_version: "v1"
      })

    {:ok, _} =
      ReviewQueue.enqueue(%{
        item_id: "b",
        stage: :cleaning,
        confidence: 0.2,
        model_version: "v1"
      })

    {:ok, _view, html} = live(conn, ~p"/queue")
    assert html =~ "/edit-cleaning/b"
    assert html =~ "/edit-extraction/a"
    assert :binary.match(html, "b") |> elem(0) < :binary.match(html, "a") |> elem(0)
  end
end
```

- [ ] **Step 2: Verify failure**

```bash
cd ~/projects/alambic && mix test test/alambic_web/live/queue_live_test.exs 2>&1 | tail -5
```

- [ ] **Step 3: Add the route**

In `lib/alambic_web/router.ex`, extend the browser scope:

```elixir
  scope "/", AlambicWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/queue", QueueLive, :index
  end
```

- [ ] **Step 4: Implement QueueLive**

Create `lib/alambic_web/live/queue_live.ex`:

```elixir
defmodule AlambicWeb.QueueLive do
  use AlambicWeb, :live_view

  alias Alambic.ReviewQueue

  def mount(_params, _session, socket) do
    {:ok, assign(socket, entries: ReviewQueue.list_pending())}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl p-6">
      <h1 class="text-2xl font-semibold mb-4">Review queue</h1>

      <%= if @entries == [] do %>
        <p class="text-zinc-500">Review queue is empty.</p>
      <% else %>
        <ul class="divide-y divide-zinc-200">
          <li :for={e <- @entries} class="py-2 flex justify-between items-center">
            <div>
              <div class="font-medium">{e.item_id}</div>
              <div class="text-sm text-zinc-500">
                {e.stage} · confidence {Float.round(e.confidence, 3)}
              </div>
            </div>
            <.link
              navigate={correction_path(e)}
              class="text-sm text-blue-600 hover:underline"
            >
              Review →
            </.link>
          </li>
        </ul>
      <% end %>
    </div>
    """
  end

  defp correction_path(%{stage: :extraction, item_id: id}), do: ~p"/edit-extraction/#{id}"
  defp correction_path(%{stage: :cleaning, item_id: id}), do: ~p"/edit-cleaning/#{id}"
end
```

- [ ] **Step 5: Run test**

```bash
cd ~/projects/alambic && mix test test/alambic_web/live/queue_live_test.exs
```

Expected: pass. (The `~p` sigils for the correction paths require those routes to exist as defined in Task 13; the test won't fail on that because verified routes are compile-warnings, not errors. If a compile-time warning fails the test build, complete Task 13 then come back and re-run.)

- [ ] **Step 6: Commit**

```bash
cd ~/projects/alambic && git add -A && git commit -m "feat: QueueLive listing pending review entries"
```

---

## Task 13: HTML sanitizer + correction LiveViews

**Files:**
- Create: `lib/alambic/html_sanitizer.ex`
- Create: `test/alambic/html_sanitizer_test.exs`
- Modify: `lib/alambic_web/router.ex`
- Create: `lib/alambic_web/live/edit_extraction_live.ex`
- Create: `lib/alambic_web/live/edit_cleaning_live.ex`
- Create: `test/alambic_web/live/edit_extraction_live_test.exs`
- Create: `test/alambic_web/live/edit_cleaning_live_test.exs`

- [ ] **Step 1: Failing sanitizer test**

Create `test/alambic/html_sanitizer_test.exs`:

```elixir
defmodule Alambic.HtmlSanitizerTest do
  use ExUnit.Case, async: true

  alias Alambic.HtmlSanitizer

  test "drops script, style, iframe, object, embed, noscript, link" do
    input = """
    <p>keep</p>
    <script>alert(1)</script>
    <style>body{display:none}</style>
    <iframe src="x"></iframe>
    <object data="x"></object>
    <embed src="x" />
    <noscript>foo</noscript>
    <link rel="stylesheet" href="x" />
    """

    out = HtmlSanitizer.sanitize(input, "item-1")
    assert out =~ "<p>keep</p>"
    refute out =~ "alert"
    refute out =~ "<script"
    refute out =~ "<style"
    refute out =~ "<iframe"
    refute out =~ "<object"
    refute out =~ "<embed"
    refute out =~ "<noscript"
    refute out =~ "<link"
  end

  test "strips on* event handler attributes" do
    out = HtmlSanitizer.sanitize(~s(<a href="/x" onclick="boom()">go</a>), "item-1")
    assert out =~ ~s(href="/x")
    refute out =~ "onclick"
  end

  test "rewrites img src to the cham-archived asset URL" do
    Application.put_env(:alambic, :cham_base_url, "http://cham.test")
    url = "https://example.com/photo.jpg"
    md5 = :crypto.hash(:md5, url) |> Base.encode16(case: :lower)

    out =
      HtmlSanitizer.sanitize(
        ~s(<img src="#{url}" srcset="#{url} 2x" alt="a">),
        "item-1"
      )

    assert out =~ ~s|src="http://cham.test/api/v1/items/item-1/files/img_#{md5}.jpg"|
    refute out =~ "srcset"
    assert out =~ ~s(alt="a")
  end

  test "drops img src when the URL has no usable extension" do
    out = HtmlSanitizer.sanitize(~s(<img src="https://example.com/photo" alt="a">), "item-1")
    refute out =~ "src="
    assert out =~ ~s(alt="a")
  end

  test "returns empty string on unparseable input" do
    assert HtmlSanitizer.sanitize(:not_a_string, "item-1") == ""
  end
end
```

- [ ] **Step 2: Verify failure**

```bash
cd ~/projects/alambic && mix test test/alambic/html_sanitizer_test.exs 2>&1 | tail -5
```

Expected: `Alambic.HtmlSanitizer` not defined.

- [ ] **Step 3: Implement the sanitizer**

Create `lib/alambic/html_sanitizer.ex`:

```elixir
defmodule Alambic.HtmlSanitizer do
  @moduledoc """
  Strips dangerous content from HTML before display and rewrites `<img>`
  sources to point at Cham's archived copy of each image.

  Drops scripts, styles, frames, and other interactive/embedded content
  entirely. Removes event-handler attributes (`on*`). For images, drops
  `srcset` and rewrites `src` to the Cham archive URL, mirroring Cham's
  download_images plugin filename scheme: `img_<md5(url)><ext>` where
  `ext` is the lowercased extension from the URL's last path segment
  (kept only when 2–6 chars including the dot). If no usable extension
  is present, the src is dropped.
  """

  @drop_tags ~w(script style iframe object embed noscript link)

  @spec sanitize(binary, String.t()) :: String.t()
  def sanitize(html, item_id) when is_binary(html) and is_binary(item_id) do
    case Floki.parse_document(html) do
      {:ok, tree} -> tree |> walk(item_id) |> Floki.raw_html()
      {:error, _} -> ""
    end
  end

  def sanitize(_, _), do: ""

  defp walk(nodes, item_id) when is_list(nodes),
    do: Enum.flat_map(nodes, &walk_node(&1, item_id))

  defp walk_node({tag, _attrs, _children}, _item_id) when tag in @drop_tags, do: []

  defp walk_node({"img", attrs, children}, item_id) do
    rewritten =
      attrs
      |> Enum.reject(fn {k, _} -> k == "srcset" end)
      |> strip_event_attrs()
      |> rewrite_img_src(item_id)

    [{"img", rewritten, walk(children, item_id)}]
  end

  defp walk_node({tag, attrs, children}, item_id) when is_binary(tag) do
    [{tag, strip_event_attrs(attrs), walk(children, item_id)}]
  end

  defp walk_node(other, _item_id), do: [other]

  defp rewrite_img_src(attrs, item_id) do
    case List.keyfind(attrs, "src", 0) do
      {"src", url} ->
        case cham_asset_url(url, item_id) do
          {:ok, new_url} -> List.keyreplace(attrs, "src", 0, {"src", new_url})
          :error -> List.keydelete(attrs, "src", 0)
        end

      nil ->
        attrs
    end
  end

  defp cham_asset_url(url, item_id) do
    with {:ok, ext} <- extension_for(url) do
      md5 = :crypto.hash(:md5, url) |> Base.encode16(case: :lower)
      base = Application.fetch_env!(:alambic, :cham_base_url)
      {:ok, "#{base}/api/v1/items/#{URI.encode(item_id)}/files/img_#{md5}#{ext}"}
    end
  end

  defp extension_for(url) do
    last_segment = url |> URI.parse() |> Map.get(:path, "") |> Path.basename()

    case String.split(last_segment, ".") do
      [_ | _] = parts when length(parts) >= 2 ->
        ext = "." <> (parts |> List.last() |> String.downcase())

        if String.length(ext) in 2..6 and Regex.match?(~r/^\.[a-z0-9]+$/, ext) do
          {:ok, ext}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp strip_event_attrs(attrs) do
    Enum.reject(attrs, fn {k, _v} -> String.starts_with?(k, "on") end)
  end
end
```

- [ ] **Step 4: Run sanitizer test**

```bash
cd ~/projects/alambic && mix test test/alambic/html_sanitizer_test.exs
```

Expected: pass.

- [ ] **Step 5: Failing LiveView tests**

Create `test/alambic_web/live/edit_extraction_live_test.exs`:

```elixir
defmodule AlambicWeb.EditExtractionLiveTest do
  use AlambicWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mox

  alias Alambic.Extractions
  alias Alambic.ReviewQueue

  setup :verify_on_exit!

  test "renders sanitized fetched HTML inline", %{conn: conn} do
    expect(Alambic.ChamMock, :fetch_html, fn "abc" ->
      {:ok, ~s(<html><body><p>hi</p><script>alert(1)</script></body></html>)}
    end)

    {:ok, _view, html} = live(conn, ~p"/edit-extraction/abc")
    assert html =~ "<p>hi</p>"
    refute html =~ "alert"
    refute html =~ "<script"
  end

  test "renders a fetch error when Cham fails", %{conn: conn} do
    expect(Alambic.ChamMock, :fetch_html, fn _ -> {:error, {:status, 404}} end)

    {:ok, _view, html} = live(conn, ~p"/edit-extraction/missing")
    assert html =~ "Could not fetch HTML"
  end

  test "confirm writes an extraction and resolves the queue", %{conn: conn} do
    expect(Alambic.ChamMock, :fetch_html, fn _ -> {:ok, "<html/>"} end)

    {:ok, _} =
      ReviewQueue.enqueue(%{
        item_id: "abc",
        stage: :extraction,
        confidence: 0.1,
        model_version: "v1"
      })

    {:ok, view, _html} = live(conn, ~p"/edit-extraction/abc")
    view |> element("button", "Confirm") |> render_click()

    assert %{xpath: "/html/body"} = Extractions.get("abc")
    assert ReviewQueue.list_pending() == []
  end
end
```

Create `test/alambic_web/live/edit_cleaning_live_test.exs`:

```elixir
defmodule AlambicWeb.EditCleaningLiveTest do
  use AlambicWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Mox

  alias Alambic.Cleanings
  alias Alambic.ReviewQueue

  setup :verify_on_exit!

  test "renders fetched HTML and a placeholder annotation pane", %{conn: conn} do
    expect(Alambic.ChamMock, :fetch_html, fn _ -> {:ok, "<html/>"} end)

    {:ok, _view, html} = live(conn, ~p"/edit-cleaning/abc")
    assert html =~ "Token annotation"
  end

  test "confirm writes a cleaning and resolves the queue", %{conn: conn} do
    expect(Alambic.ChamMock, :fetch_html, fn _ -> {:ok, "<html/>"} end)

    {:ok, _} =
      ReviewQueue.enqueue(%{
        item_id: "abc",
        stage: :cleaning,
        confidence: 0.1,
        model_version: "v1"
      })

    {:ok, view, _html} = live(conn, ~p"/edit-cleaning/abc")
    view |> element("button", "Confirm") |> render_click()

    assert %Alambic.Cleanings.Cleaning{} = Cleanings.get("abc")
    assert ReviewQueue.list_pending() == []
  end
end
```

- [ ] **Step 6: Verify failure**

```bash
cd ~/projects/alambic && mix test test/alambic_web/live/edit_extraction_live_test.exs test/alambic_web/live/edit_cleaning_live_test.exs 2>&1 | tail -5
```

- [ ] **Step 7: Add the routes**

In `lib/alambic_web/router.ex`, the browser scope is now:

```elixir
  scope "/", AlambicWeb do
    pipe_through :browser

    get "/", PageController, :home
    live "/queue", QueueLive, :index
    live "/edit-extraction/:item_id", EditExtractionLive, :show
    live "/edit-cleaning/:item_id", EditCleaningLive, :show
  end
```

- [ ] **Step 8: Implement EditExtractionLive**

Create `lib/alambic_web/live/edit_extraction_live.ex`:

```elixir
defmodule AlambicWeb.EditExtractionLive do
  use AlambicWeb, :live_view

  alias Alambic.{Cham, Extractions, HtmlSanitizer, ReviewQueue}

  @placeholder_xpath "/html/body"

  def mount(%{"item_id" => item_id}, _session, socket) do
    case Cham.fetch_html(item_id) do
      {:ok, raw_html} ->
        {:ok,
         assign(socket,
           item_id: item_id,
           raw_html: raw_html,
           safe_html: HtmlSanitizer.sanitize(raw_html, item_id),
           error: nil
         )}

      {:error, reason} ->
        {:ok,
         assign(socket,
           item_id: item_id,
           raw_html: nil,
           safe_html: nil,
           error: inspect(reason)
         )}
    end
  end

  def handle_event("confirm", _params, socket) do
    {:ok, _} =
      Extractions.save(%{
        item_id: socket.assigns.item_id,
        xpath: @placeholder_xpath,
        html_snapshot: socket.assigns.raw_html || ""
      })

    :ok = ReviewQueue.resolve(socket.assigns.item_id, :extraction)
    {:noreply, put_flash(socket, :info, "Extraction confirmed.")}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl p-6">
      <h1 class="text-2xl font-semibold mb-2">Edit extraction · {@item_id}</h1>
      <p class="text-sm text-zinc-500 mb-4">
        Placeholder UI: the real DOM picker will render the page in a sandboxed iframe.
      </p>

      <%= if @error do %>
        <div class="rounded bg-red-50 p-3 text-red-700 text-sm">
          Could not fetch HTML: {@error}
        </div>
      <% else %>
        <div class="rounded border bg-white p-3 overflow-auto text-sm">
          {Phoenix.HTML.raw(@safe_html)}
        </div>
      <% end %>

      <button
        phx-click="confirm"
        class="mt-4 rounded bg-blue-600 px-3 py-2 text-white text-sm hover:bg-blue-700"
      >
        Confirm
      </button>
    </div>
    """
  end
end
```

- [ ] **Step 9: Implement EditCleaningLive**

Create `lib/alambic_web/live/edit_cleaning_live.ex`:

```elixir
defmodule AlambicWeb.EditCleaningLive do
  use AlambicWeb, :live_view

  alias Alambic.{Cham, Cleanings, HtmlSanitizer, ReviewQueue}

  def mount(%{"item_id" => item_id}, _session, socket) do
    case Cham.fetch_html(item_id) do
      {:ok, raw_html} ->
        {:ok,
         assign(socket,
           item_id: item_id,
           raw_html: raw_html,
           safe_html: HtmlSanitizer.sanitize(raw_html, item_id),
           error: nil
         )}

      {:error, reason} ->
        {:ok,
         assign(socket,
           item_id: item_id,
           raw_html: nil,
           safe_html: nil,
           error: inspect(reason)
         )}
    end
  end

  def handle_event("confirm", _params, socket) do
    {:ok, _} =
      Cleanings.save(%{
        item_id: socket.assigns.item_id,
        token_labels: [%{"token" => "placeholder", "label" => "keep"}],
        source_text: "placeholder"
      })

    :ok = ReviewQueue.resolve(socket.assigns.item_id, :cleaning)
    {:noreply, put_flash(socket, :info, "Cleaning confirmed.")}
  end

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl p-6">
      <h1 class="text-2xl font-semibold mb-2">Edit cleaning · {@item_id}</h1>
      <p class="text-sm text-zinc-500 mb-4">
        Placeholder UI: Token annotation pane will replace this once real models exist.
      </p>

      <%= if @error do %>
        <div class="rounded bg-red-50 p-3 text-red-700 text-sm">
          Could not fetch HTML: {@error}
        </div>
      <% else %>
        <div class="rounded border bg-white p-3 mb-3">
          <h2 class="text-sm font-medium mb-2">Token annotation (placeholder)</h2>
          <p class="text-xs text-zinc-500">
            Real implementation will tokenize the extracted text and let the user toggle keep/discard.
          </p>
        </div>
        <div class="rounded border bg-white p-3 overflow-auto text-sm">
          {Phoenix.HTML.raw(@safe_html)}
        </div>
      <% end %>

      <button
        phx-click="confirm"
        class="mt-4 rounded bg-blue-600 px-3 py-2 text-white text-sm hover:bg-blue-700"
      >
        Confirm
      </button>
    </div>
    """
  end
end
```

- [ ] **Step 10: Run tests**

```bash
cd ~/projects/alambic && mix test test/alambic_web/live/ test/alambic/html_sanitizer_test.exs
```

Expected: pass.

- [ ] **Step 11: Commit**

```bash
cd ~/projects/alambic && git add -A && git commit -m "feat: HTML sanitizer + placeholder correction LiveViews"
```

---

## Task 14: Seeds, Docker, and full-suite check

**Files:**
- Modify: `priv/repo/seeds.exs`
- Modify: `Dockerfile`
- Modify: `docker-compose.yml`
- Modify: `.env.example`
- Modify: `justfile` (add `db-seed` shortcut)

- [ ] **Step 1: Seed dummy models**

Replace `priv/repo/seeds.exs` with:

```elixir
alias Alambic.Models.Model
alias Alambic.Repo

now = DateTime.utc_now() |> DateTime.truncate(:second)

for {version, stage, path} <- [
      {"extraction-dummy.1", :extraction, "scripts/extract"},
      {"cleaning-dummy.1", :cleaning, "scripts/clean"}
    ] do
  unless Repo.get(Model, version) do
    %Model{}
    |> Model.changeset(%{
      version: version,
      stage: stage,
      trained_at: now,
      artifact_path: path,
      training_sample_size: 0,
      status: :active
    })
    |> Repo.insert!()
  end
end
```

- [ ] **Step 2: Install uv in the Dockerfile runtime stage**

In `Dockerfile`, change the runtime stage's `apt-get install` line and add a uv install + scripts copy. The runtime stage should become:

```dockerfile
# --- Runtime ---
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y libstdc++6 openssl libncurses6 locales curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Install uv (single static binary)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

WORKDIR /app

COPY --from=build /app/_build/prod/rel/alambic ./
COPY scripts ./scripts

COPY entrypoint.sh ./
RUN chmod +x entrypoint.sh

ENV PORT=4000 \
    UV_CACHE_DIR=/root/.cache/uv
EXPOSE 4000

ENTRYPOINT ["./entrypoint.sh"]
```

- [ ] **Step 3: Add uv_cache volume to docker-compose**

In `docker-compose.yml`, change the `alambic` service's `volumes:` list to include `uv_cache` and add it to the top-level `volumes:` map:

```yaml
  alambic:
    build: .
    restart: unless-stopped
    ports:
      - "${PORT:-4000}:4000"
    volumes:
      - model_artifacts:/data/models
      - uv_cache:/root/.cache/uv
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DATABASE_URL: ecto://alambic:${POSTGRES_PASSWORD:-alambic}@postgres/alambic
      SECRET_KEY_BASE: ${SECRET_KEY_BASE:?Set SECRET_KEY_BASE}
      PHX_HOST: ${PHX_HOST:?Set PHX_HOST}
      ARCHIVE_BASE_URL: ${ARCHIVE_BASE_URL:?Set ARCHIVE_BASE_URL}
      MODEL_ARTIFACTS_PATH: /data/models
      REVIEW_CONFIDENCE_THRESHOLD: ${REVIEW_CONFIDENCE_THRESHOLD:-0.7}
      CHAM_RAW_HTML_FILENAME: ${CHAM_RAW_HTML_FILENAME:-original.html}
      PORT: "4000"

volumes:
  pgdata:
  model_artifacts:
  uv_cache:
```

- [ ] **Step 4: Add Cham filename to .env.example**

Append to `.env.example`:

```
# Cham filename for the raw HTML artifact per item
CHAM_RAW_HTML_FILENAME=original.html
```

- [ ] **Step 5: Add db-seed to justfile**

In `justfile`, append:

```
# Seed dummy models so /api/extract and /api/clean aren't 503 on a fresh DB
db-seed:
    mix run priv/repo/seeds.exs
```

- [ ] **Step 6: Full check**

```bash
cd ~/projects/alambic && just check
```

Expected: format check passes, project compiles without warnings, credo passes, tests pass.

If dialyzer is too slow on a fresh checkout, run the cheaper subset:

```bash
cd ~/projects/alambic && mix format --check-formatted && mix compile --warnings-as-errors && mix test
```

- [ ] **Step 7: Smoke-test the full app end-to-end**

```bash
cd ~/projects/alambic && mix ecto.reset && just db-seed
```

In one shell: `cd ~/projects/alambic && just server`

In another:

```bash
curl -s -X POST http://localhost:4000/api/extract \
  -H 'content-type: application/json' \
  -d '{"item_id":"abc","html":"<html/>"}'
```

Expected: `{"item_id":"abc","xpath":"/","source":"model","model_version":"extraction-dummy.1","confidence":null}`

```bash
curl -s -X POST http://localhost:4000/api/clean \
  -H 'content-type: application/json' \
  -d '{"item_id":"abc","text":"hi"}'
```

Expected: `{"item_id":"abc","cleaned_text":"foo","source":"model","model_version":"cleaning-dummy.1","confidence":null}`

```bash
curl -s http://localhost:4000/api/models
```

Expected: array of two model rows.

Browse to <http://localhost:4000/queue> — should render "Review queue is empty.".

- [ ] **Step 8: Commit**

```bash
cd ~/projects/alambic && git add -A && git commit -m "feat: seed dummy models, Docker uv install, uv cache volume"
```

---

## Done condition

- `just check` passes (format, compile, credo, dialyzer, test).
- Manual curl checks against `/api/extract`, `/api/clean`, `/api/models` return the documented shapes.
- `/queue` and both correction LiveViews render with seeded data.
- Cham filename remains a flagged open question in the spec; no real ML code exists; no reprocess call exists anywhere in the codebase.
