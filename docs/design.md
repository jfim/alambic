# Alambic — Design

## Overview

Alambic is a two-stage web article distillation service. Stage 1 (extraction) identifies the article body element in raw HTML and returns an XPath expression. Stage 2 (cleaning) takes the extracted text and removes non-article content (navigation bleed, sponsor notices, footers, etc.) through token-level classification. Both stages support human correction via a web UI and feed labeled data into independent retraining pipelines.

---

## REST API

### `POST /extract`

Runs stage 1. Accepts raw HTML, returns an XPath expression.

**Request**
```json
{
  "item_id": "string",
  "html": "string"
}
```

**Behavior**
1. If a saved XPath exists in the database for `item_id`, return it directly
2. Otherwise, run the active extraction model and return the predicted XPath

**Response**
```json
{
  "item_id": "string",
  "xpath": "string",
  "source": "saved | model",
  "model_version": "string | null",
  "confidence": "float | null"
}
```

`confidence` and `model_version` are null when `source` is `saved`.

---

### `POST /clean`

Runs stage 2. Accepts extracted text, returns cleaned text.

**Request**
```json
{
  "item_id": "string",
  "text": "string"
}
```

**Behavior**
1. If saved token labels exist for `item_id`, apply them and return
2. Otherwise, run the active cleaning model and return the cleaned result

**Response**
```json
{
  "item_id": "string",
  "cleaned_text": "string",
  "source": "saved | model",
  "model_version": "string | null",
  "confidence": "float | null"
}
```

> [!NOTE] Comment
> What's confidence? min(confidence) across all tokens?

---

**Errors (all endpoints)**
- `422` — input could not be parsed
- `503` — no model available for the requested stage

---

## Database


> [!NOTE] Comment
> I don't think we should store HTML in the database, maybe a zstd/gzip/brotli blob in S3 like storage and the URL for it? We should probably only store ones that were entered by the user, not all HTML blobs, since we can always get the HTML blobs back from the archive


### `extractions`
| column | type | notes |
|---|---|---|
| item_id | string PK | |
| xpath | string | User-confirmed XPath |
| html_snapshot | text | HTML at time of confirmation |
| confirmed_at | timestamp | |
| model_version | string \| null | Extraction model that produced the initial prediction |

> [!NOTE] Comment
> Same for text and ground truth, should be stored outside of the DB

### `cleanings`
| column | type | notes |
|---|---|---|
| item_id | string PK | |
| token_labels | jsonb | Array of `{token, label}` where label is `keep` or `discard` |
| source_text | text | Text submitted for cleaning at time of confirmation |
| confirmed_at | timestamp | |
| model_version | string \| null | Cleaning model that produced the initial prediction |
> [!NOTE] Comment
> Maybe we'd need an API to push models?
### `models`
| column | type | notes |
|---|---|---|
| version | string PK | e.g. `extraction-2024-05-21.1` |
| stage | enum | `extraction \| cleaning` |
| trained_at | timestamp | |
| artifact_path | string | |
| training_sample_size | int | |
| status | enum | `active \| retired \| failed` |

Exactly one model per stage carries `active` status at any time.

### `review_queue`
| column | type | notes |
|---|---|---|
| item_id | string | |
| stage | enum | `extraction \| cleaning` |
| confidence | float | |
| model_version | string | |
| queued_at | timestamp | |
| resolved_at | timestamp \| null | |

Items are added when confidence falls below `REVIEW_CONFIDENCE_THRESHOLD`. Confirming a correction in either UI marks the entry resolved. Primary key is `(item_id, stage)`.

---

## Web UI

> [!NOTE] Comment
> Maybe different paths, /edit-extraction/{id}, /edit-cleaning/{id}?

### `GET /edit/{item_id}` — Extraction correction

1. Fetch raw HTML from the archive artifact API
2. Call `/extract` internally for the current XPath
3. Render the page in a sandboxed iframe with a DOM picker injected; current selection highlighted
4. On confirmation: save to `extractions`, save HTML snapshot, call the archive reprocess API, mark any queue entry resolved

### `GET /clean/{item_id}` — Cleaning correction

1. Fetch raw HTML from archive, run `/extract` to get the text content
2. Call `/clean` internally for current token labels
3. Render the extracted text as an inline annotation UI; tokens labeled `discard` are shown struck through or dimmed, `keep` tokens are shown normally; the user can toggle individual spans
4. On confirmation: save to `cleanings`, save source text, call the archive reprocess API, mark any queue entry resolved

### `GET /queue` — Review queue

Lists all unresolved entries across both stages, ordered by confidence ascending. Each row links to the appropriate correction UI (`/edit/` or `/clean/`).

---

## Admin API

- `GET /models` — list all models with stage, status, and metadata
- `POST /models/{version}/activate` — promote a model to active for its stage, retiring the current one

---

## Training

Each stage has an independent training pipeline. A run for either stage:

1. Pulls confirmed corrections for that stage as labeled ground truth
2. Trains a new model
3. Registers the result in `models` with `status = active`, retiring the previous

The training process itself is out of scope for this spec beyond its interface with the model registry.

---

## Archive Plugin Integration

The extractor plugin calls `POST /distill` (or both endpoints separately) and stores the returned XPath and cleaned text as artifacts. It also stores the `item_id` for later reference.

The plugin exposes correction links in the archive UI when confidence is below threshold:

```
⚠ Low confidence extraction — review at https://.../edit/{item_id}
⚠ Low confidence cleaning — review at https://.../clean/{item_id}
```

The threshold check lives in the plugin using the returned confidence values.

---

## Configuration

| key | description |
|---|---|
| `ARCHIVE_BASE_URL` | Base URL of the archive API |
| `DATABASE_URL` | |
| `MODEL_ARTIFACTS_PATH` | Path or object storage prefix for model weights |
| `REVIEW_CONFIDENCE_THRESHOLD` | Confidence below which items are queued for review |

---

## Open Questions

- **Archive authentication** — does Alambic need credentials to call the archive API?
- **HTML snapshot retention policy** — keep forever, or prune after some period?
- **Training schedule** — manual-only initially, or build a scheduler in from the start?
- **Cleaning input source** — does `/clean` always re-run `/extract` internally, or does the caller supply the already-extracted text? The current spec has the caller supply it, which is more flexible but requires the archive plugin to chain the calls explicitly.
