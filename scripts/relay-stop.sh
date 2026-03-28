#!/bin/bash
# ============================================================
# relay-stop.sh — Stop a running relay and notify The Desk
# ============================================================

NANOCLAW_DIR="/home/garrett/nanoclaw"
PID_FILE="$NANOCLAW_DIR/data/relay.pid"
TELEGRAM_TOKEN="$(grep '^TELEGRAM_BOT_TOKEN=' "$NANOCLAW_DIR/.env" | cut -d= -f2)"
DESK_CHAT_ID="-5055447496"

send_telegram() {
    local msg="$1"
    local payload
    payload=$(python3 -c "
import sys, json
msg = sys.stdin.read()
print(json.dumps({'chat_id': '$DESK_CHAT_ID', 'text': msg}))
" <<< "$msg")
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || true
}

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        kill "$PID"
        rm -f "$PID_FILE"
        echo "Relay stopped (PID $PID)"
        send_telegram "Relay stopped manually via relay-stop.sh (PID $PID)"
    else
        rm -f "$PID_FILE"
        echo "Relay was not running (stale PID file cleaned up)"
    fi
else
    echo "No relay running (no PID file found)"
fi
