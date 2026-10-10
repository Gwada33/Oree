#!/bin/bash
# Notes de version = les sujets des commits depuis le dernier tag.
#   ./scripts/release-notes.sh [depuis]   (par défaut : dernier tag v*)   --count : seulement le nombre de commits
set -euo pipefail
cd "$(dirname "$0")/.."
COUNT=0; [ "${1:-}" = "--count" ] && { COUNT=1; shift; }
FROM="${1:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)}"
RANGE="${FROM:+$FROM..}HEAD"
LOG="$(git log --no-merges --pretty='- %s' "$RANGE" | grep -vE '^- (Version [0-9]|Merge )' || true)"
if [ "$COUNT" = 1 ]; then [ -z "$LOG" ] && echo 0 || echo "$LOG" | wc -l | tr -d ' '; exit 0; fi
echo "${LOG:-- Améliorations et corrections.}"
