#!/bin/bash
# Bridge trigger files from NanoClaw group folders to the host relay-trigger directory
# Watches all group folders for relay trigger files written by Clutch inside containers

NANOCLAW_DIR="/home/garrett/nanoclaw"
TRIGGER_DIR="$NANOCLAW_DIR/data/relay-triggers"
GROUPS_DIR="$NANOCLAW_DIR/groups"

mkdir -p "$TRIGGER_DIR"

echo "[relay-bridge] Watching group folders for relay triggers..."

inotifywait -m -r -e create -e modify "$GROUPS_DIR" --format '%w%f' 2>/dev/null | while read FILEPATH; do
    FILENAME=$(basename "$FILEPATH")

    if [[ "$FILENAME" == "relay-start-trigger.txt" ]]; then
        PROJECT_DIR=$(cat "$FILEPATH" 2>/dev/null | tr -d '[:space:]')
        rm -f "$FILEPATH"
        if [ -n "$PROJECT_DIR" ]; then
            echo "[relay-bridge] Start trigger: $PROJECT_DIR"
            echo "$PROJECT_DIR" > "$TRIGGER_DIR/start-$(date +%s)"
        fi
    elif [[ "$FILENAME" == "relay-stop-trigger.txt" ]]; then
        rm -f "$FILEPATH"
        echo "[relay-bridge] Stop trigger received"
        touch "$TRIGGER_DIR/stop"
    fi
done
