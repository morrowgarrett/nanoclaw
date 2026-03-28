#!/bin/bash
# Watch for relay trigger files and start/stop relays
# Runs on the host as a systemd service

TRIGGER_DIR="/home/garrett/nanoclaw/data/relay-triggers"
NANOCLAW_DIR="/home/garrett/nanoclaw"
mkdir -p "$TRIGGER_DIR"

echo "[relay-trigger] Watching $TRIGGER_DIR for triggers..."

inotifywait -m -e create "$TRIGGER_DIR" --format '%f' 2>/dev/null | while read FILE; do
    if [[ "$FILE" == start-* ]]; then
        PROJECT_DIR=$(cat "$TRIGGER_DIR/$FILE" 2>/dev/null)
        rm -f "$TRIGGER_DIR/$FILE"

        if [ -z "$PROJECT_DIR" ] || [ ! -f "$PROJECT_DIR/BRIEF.md" ]; then
            echo "[relay-trigger] Invalid project dir: $PROJECT_DIR"
            continue
        fi

        # Stop any existing relay
        bash "$NANOCLAW_DIR/scripts/relay-stop.sh" 2>/dev/null

        echo "[relay-trigger] Starting relay on $PROJECT_DIR"
        nohup "$NANOCLAW_DIR/scripts/relay.sh" "$PROJECT_DIR" 10 > /tmp/relay-output.log 2>&1 &
        echo "[relay-trigger] Relay started PID: $!"

    elif [[ "$FILE" == "stop" ]]; then
        rm -f "$TRIGGER_DIR/$FILE"
        echo "[relay-trigger] Stopping relay"
        bash "$NANOCLAW_DIR/scripts/relay-stop.sh"
    fi
done
