#!/usr/bin/env bash
#
# Enqueue the first N article IDs from `cham item list` (newest items
# come first) into the cleaning review queue on prod (alambic running in
# docker on jfim-dedibox-b).
#
# Usage:
#   scripts/enqueue-cleaning-review.sh [count]
#
#   count   number of leading (newest) items to enqueue (default: 100)
#
# Dry-run (just print the IDs, don't touch prod):
#   DRY_RUN=1 scripts/enqueue-cleaning-review.sh 50
#
set -euo pipefail

COUNT="${1:-100}"
SSH_HOST="${SSH_HOST:-jfim@jfim-dedibox-b}"
CONTAINER="${CONTAINER:-alambic}"
MODEL_VERSION="${MODEL_VERSION:-manual}"

if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  echo "error: count must be a non-negative integer, got: $COUNT" >&2
  exit 1
fi

ids_json="$(cham item list --type article --json | jq -c "[.[:${COUNT}] | .[].id]")"
id_count="$(jq 'length' <<<"$ids_json")"

if [[ "$id_count" -eq 0 ]]; then
  echo "no items returned by cham; nothing to enqueue" >&2
  exit 0
fi

echo "selected $id_count item ids (first $COUNT of cham item list)" >&2

# Build the remote iex snippet. We embed the JSON list literal directly into
# Elixir — JSON arrays of strings are valid Elixir list literals, so no parsing
# needed on the remote side.
read -r -d '' SNIPPET <<EOF || true
ids = ${ids_json}
results =
  Enum.map(ids, fn id ->
    {id,
     Alambic.ReviewQueue.enqueue(%{
       item_id: id,
       stage: :cleaning,
       confidence: 0.0,
       model_version: "${MODEL_VERSION}"
     })}
  end)

IO.inspect(Enum.frequencies_by(results, fn {_, {status, _}} -> status end),
  label: "enqueue result"
)
EOF

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "--- DRY_RUN: would pipe the following to ${SSH_HOST} \`docker exec -i ${CONTAINER} /app/bin/alambic remote\` ---"
  printf '%s\n' "$SNIPPET"
  exit 0
fi

printf '%s\n' "$SNIPPET" | ssh "$SSH_HOST" "docker exec -i ${CONTAINER} /app/bin/alambic remote"
