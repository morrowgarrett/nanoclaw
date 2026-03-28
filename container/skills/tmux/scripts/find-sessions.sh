#!/bin/bash
# List tmux sessions, optionally on a remote host
HOST="${1:-}"
FILTER="${2:-}"

if [ -n "$HOST" ]; then
  SESSIONS=$(ssh -o ConnectTimeout=5 "$HOST" "tmux list-sessions 2>/dev/null" 2>/dev/null) || {
    echo "Could not connect to $HOST or no tmux sessions found"
    exit 1
  }
else
  SESSIONS=$(tmux list-sessions 2>/dev/null) || {
    echo "No local tmux sessions found"
    exit 1
  }
fi

if [ -n "$FILTER" ]; then
  echo "$SESSIONS" | grep -i "$FILTER"
else
  echo "$SESSIONS"
fi
