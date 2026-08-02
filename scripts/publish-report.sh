#!/usr/bin/env bash
# Publish a standalone HTML report to https://reports.ringbell.cc/<slug>.
# Usage: scripts/publish-report.sh <file.html> [slug]
set -euo pipefail

FILE=${1:?"usage: publish-report.sh <file.html> [slug]"}
[[ -f "$FILE" ]] || { echo "no such file: $FILE" >&2; exit 1; }

SLUG=${2:-$(basename "$FILE" .html)}
# normalize: lowercase, non [a-z0-9] -> '-', trim dashes, max 63 chars, must start alnum
SLUG=$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-63)
[[ "$SLUG" =~ ^[a-z0-9] ]] || SLUG="r$SLUG"
[[ -n "$SLUG" ]] || { echo "could not derive a valid slug" >&2; exit 1; }

BASE=${REPORTS_BASE_URL:-https://reports.ringbell.cc}
TOKEN=$(pass show homelab/reports/api-token)

curl -fsS -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: text/html; charset=utf-8" \
  --data-binary @"$FILE" \
  "$BASE/api/reports/$SLUG" >/dev/null

echo "$BASE/$SLUG"
