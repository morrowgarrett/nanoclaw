#!/usr/bin/env bash
# autoDream cron wrapper — runs consolidation against the memU sidecar.
# Cron entry: 30 3 * * * /home/garrett/nanoclaw/scripts/dream-cron.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load environment
if [ -f "$PROJECT_DIR/.env.memu" ]; then
    set -a
    source "$PROJECT_DIR/.env.memu"
    set +a
fi

export MEMU_SIDECAR_URL="${MEMU_SIDECAR_URL:-http://localhost:8100}"
export OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"
export DREAM_LOG_DIR="$PROJECT_DIR/logs"
export DREAM_CHAT_MODEL="${DREAM_CHAT_MODEL:-qwen3:0.6b}"

mkdir -p "$PROJECT_DIR/logs"

exec python3 "$PROJECT_DIR/memu-framework/dream.py" \
    >> "$PROJECT_DIR/logs/dream.log" 2>&1
