#!/bin/bash
# Poll a tmux pane until a regex pattern appears
set -euo pipefail

HOST="${1:?Usage: wait-for-text.sh <host> <session> <pattern> [timeout] [interval]}"
SESSION="${2:?}"
PATTERN="${3:?}"
TIMEOUT="${4:-60}"
INTERVAL="${5:-2}"

ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  OUTPUT=$(ssh -o ConnectTimeout=5 "$HOST" "tmux capture-pane -t '$SESSION' -p" 2>/dev/null) || true
  if echo "$OUTPUT" | grep -qE "$PATTERN"; then
    echo "Pattern found after ${ELAPSED}s:"
    echo "$OUTPUT" | grep -E "$PATTERN"
    exit 0
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "Timeout after ${TIMEOUT}s — pattern not found: $PATTERN"
exit 1
