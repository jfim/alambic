# Alambic Scaffolding — Design

**Status:** Draft, awaiting user review
**Date:** 2026-05-21
**Companion spec:** [`docs/design.md`](../../design.md) (upstream system spec)

## Purpose

Stand up the Phoenix application end-to-end against the spec in `docs/design.md`, with **no real ML models**. The goal is to validate the spec by walking the routes, schemas, and screens — surfacing wording or shape problems before any model work begins. Real model artifacts and the training pipeline are out of scope.

A `uv`-based Python script runner is included now (mirroring `cham-v2`) with stub scripts, so the model-invocation path is exercised end-to-end with dummy output. Real scripts replace the stubs later without touching the Elixir side.

## Scope

### In

- Phoenix routes for every spec endpoint, with `/api` prefix on machine-facing endpoints (`/extract`, `/clean`, `/models`) and bare paths for browser-facing LiveViews (`/edit-extraction/:id`, `/edit-cleaning/:id`, `/queue`).
- Ecto schemas and migrations for `extractions`, `cleanings`, `models`, `review_queue` exactly as specified in `docs/design.md` (HTML/text stored in-DB; S3-style blob storage deferred until training shape is known).
- `Alambic.Cham` HTTP client, **read-only**: fetches raw HTML via `GET /api/v1/items/:id/files/:filename` against a configured `CHAM_BASE_URL`. A `Behaviour` allows a fake implementation in tests. The codebase contains no reprocess call — the risk of accidentally mutating archive state is eliminated by absence.
- `Alambic.ScriptRunner` — direct port of `Cham.ScriptRunner`. Spawns `uv run scripts/<name>/main.py <input_path>` via `Port.open/2`, captures stdout, enforces a timeout.
- `scripts/extract/main.py` and `scripts/clean/main.py` — dummy implementations emitting JSON on stdout.
- Seeded `models` rows for `extraction-dummy.1` and `cleaning-dummy.1`, each pointing at the corresponding dummy script, both `status = active`. Without these the inference endpoints return 503.
- Correction LiveViews fetch HTML from Cham and render it in a placeholder pane. The DOM-picker and token-annotator UIs are placeholder divs. A "confirm" button writes a row to `extractions`/`cleanings` and marks any matching `review_queue` entry resolved — locally; no Cham callback.
- `GET /queue` lists pending `review_queue` rows in ascending-confidence order; each row links to the appropriate correction LiveView.
- Admin endpoints: `GET /api/models` lists registry rows; `POST /api/models/:version/activate` promotes a model and retires the prior active one for that stage.
- UV cache mounted as a named docker volume so dependency downloads survive container rebuilds.

### Out

- Real ML models or any code that loads weights.
- Authentication. Neither alambic nor Cham have it yet; revisit when one needs it.
- Reprocess callback to Cham.
- Training pipeline / model artifact storage. `MODEL_ARTIFACTS_PATH` env var stays defined but unused.
- `POST /distill` (confirmed removed from upstream spec).

## Routes

```
POST   /api/extract                      → ExtractController :create        (JSON)
POST   /api/clean                        → CleanController  :create        (JSON)
GET    /api/models                       → Admin.ModelController :index     (JSON)
POST   /api/models/:version/activate     → Admin.ModelController :activate  (JSON)
GET    /edit-extraction/:item_id         → EditExtractionLive               (LiveView)
GET    /edit-cleaning/:item_id           → EditCleaningLive                 (LiveView)
GET    /queue                            → QueueLive                        (LiveView)
```

## Module layout

```
lib/alambic/
  cham.ex                  # @behaviour + HTTP client (read-only)
  cham/fake.ex             # test impl
  script_runner.ex         # Port-based uv runner (port of cham-v2)
  extractions.ex           # context
  extractions/extraction.ex
  cleanings.ex             # context
  cleanings/cleaning.ex
  models.ex                # context: active_for/1, activate/1, list/0
  models/model.ex
  review_queue.ex          # context: enqueue, resolve, list_pending
  review_queue/entry.ex
  inference.ex             # facade: extract/2, clean/2 — saved vs. model branching
```

Controllers stay thin. The "saved vs. model" branching from the spec lives entirely in `Inference`. `Inference` looks up the active model via `Models.active_for/1`, hands `model.artifact_path` (which for the dummies points at a `scripts/<name>` directory) to `ScriptRunner`, then enqueues a `review_queue` entry when returned confidence falls below `REVIEW_CONFIDENCE_THRESHOLD`.

## Script contract

Stubs use the cham-v2 directory convention (`scripts/<name>/main.py` with PEP 723 inline dependencies). Input is supplied as a tempfile path on argv[1]. Output is **JSON on stdout** — chosen over raw strings so the controllers can mechanically attach `model_version` and forward the rest without per-stage parsing logic.

**`scripts/extract/main.py`**

```python
# /// script
# requires-python = ">=3.11"
# ///
import json, sys
# argv[1] = path to raw HTML (ignored by the dummy)
print(json.dumps({"xpath": "/", "confidence": None}))
```

**`scripts/clean/main.py`**

```python
# /// script
# requires-python = ">=3.11"
# ///
import json, sys
# argv[1] = path to extracted text (ignored by the dummy)
print(json.dumps({"cleaned_text": "foo", "confidence": None}))
```

The shape is forward-compatible: real models can add `model_version`, per-token labels, or any future metadata without touching the runner.

## Data model

Schemas mirror `docs/design.md` verbatim:

- `extractions` — `item_id` (string, PK), `xpath`, `html_snapshot` (text), `confirmed_at`, `model_version`.
- `cleanings` — `item_id` (string, PK), `token_labels` (jsonb), `source_text` (text), `confirmed_at`, `model_version`.
- `models` — `version` (string, PK), `stage` (enum: `extraction|cleaning`), `trained_at`, `artifact_path`, `training_sample_size`, `status` (enum: `active|retired|failed`). A partial unique index enforces "one active per stage".
- `review_queue` — `(item_id, stage)` composite PK, `confidence`, `model_version`, `queued_at`, `resolved_at`.

HTML/text columns are kept in-DB for now (lightweight volume, training shape not yet known). When training is designed, both move to object storage and the schemas grow a `*_uri` column.

## Cham integration

Read-only HTTP client behind a behaviour, against `CHAM_BASE_URL`. Single call surface used by the correction LiveViews:

```elixir
@callback fetch_html(item_id :: String.t()) :: {:ok, binary} | {:error, term}
```

**Filename convention:** confirmed as `original.html` (e.g.
`https://cham.jfim.dev/api/v1/items/<uuid>/files/original.html`). The
alambic config exposes `CHAM_RAW_HTML_FILENAME` (default `original.html`)
so the convention can be overridden without code changes when Cham's
output naming evolves.

### HTML sanitization

Cham serves the raw original HTML, which can contain scripts, remote
image loads, tracking pixels, and other interactive content. Before
rendering in the correction LiveViews, alambic sanitizes the document
with a Floki-based pass that:

- Drops `script`, `style`, `iframe`, `object`, `embed`, `noscript`, and
  `link` elements entirely.
- Strips any attribute whose name starts with `on` (event handlers).
- Strips `src` and `srcset` from `<img>` elements to prevent any remote
  fetch — the picker UI only cares about element structure for now.

This is intentionally conservative for the placeholder. A real DOM
picker will later need to keep some attribute information (`id`,
`class`, `data-*`); those are preserved today since the sanitizer only
removes the dangerous set.

## Deployment changes from current scaffold

- `Dockerfile` runtime stage installs `uv` (curl-based installer) and copies `scripts/` into the image.
- `docker-compose.yml` adds a `uv_cache` named volume mounted at `/root/.cache/uv`.
- `MODEL_ARTIFACTS_PATH` defined and forwarded to the container; not yet consumed by any code.

## Open spec issues this surfaces

1. **HTML/text storage** — DB now, blob store later. Decision blocked on training-pipeline design.
2. **Authentication** — nothing in either system today; revisit before going past localhost.
3. **Queue resolution lifecycle** — spec says "Confirming a correction in either UI marks the entry resolved." Implemented locally. The unresolved spec question is whether the *archive plugin* (or anyone else) needs to be notified — for now the answer is "no, alambic-internal only", consistent with the no-reprocess decision.

## Non-goals

- Replacing the upstream spec in `docs/design.md`. This document captures the scaffolding's design decisions and the resolutions to spec ambiguities that scaffolding forced; the upstream spec remains source of truth for the system shape.
