#!/bin/bash
# Refresh Claude OAuth token before it expires.
# Uses Claude Code itself (not raw curl) to trigger internal token refresh.
# Runs via cron every 4 hours.

CRED_FILE="$HOME/.claude/.credentials.json"
LOG="/home/garrett/nanoclaw/logs/oauth-refresh.log"
CLAUDE_BIN="$HOME/.npm-global/bin/claude"

if [ ! -f "$CRED_FILE" ]; then
    echo "$(date -Iseconds) No credentials file found" >> "$LOG"
    exit 1
fi

# Check current token expiry
EXPIRES_AT=$(python3 -c "import json; d=json.load(open('$CRED_FILE')); print(d.get('claudeAiOauth',{}).get('expiresAt',0))")
NOW_MS=$(python3 -c "import time; print(int(time.time()*1000))")
REMAINING=$((EXPIRES_AT - NOW_MS))
REMAINING_MIN=$((REMAINING / 60000))

# Skip if token is still valid for more than 2 hours
if [ "$REMAINING" -gt 7200000 ]; then
    echo "$(date -Iseconds) Token valid for $((REMAINING / 3600000))h — skipping" >> "$LOG"
    exit 0
fi

echo "$(date -Iseconds) Token expires in ${REMAINING_MIN}m — triggering refresh via Claude Code" >> "$LOG"

# Use Claude Code in print mode to make an API call, which triggers its
# internal token refresh logic. This works because Claude Code checks token
# expiry before each request and refreshes using the proper OAuth flow.
BEFORE_EXPIRY="$EXPIRES_AT"
OUTPUT=$(timeout 30 "$CLAUDE_BIN" -p "ok" --no-input 2>&1)
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo "$(date -Iseconds) Claude Code exited with code $EXIT_CODE: $OUTPUT" >> "$LOG"
    # If Claude Code fails, the token may need manual /login
    exit 1
fi

# Check if credentials were updated
NEW_EXPIRES_AT=$(python3 -c "import json; d=json.load(open('$CRED_FILE')); print(d.get('claudeAiOauth',{}).get('expiresAt',0))")
NEW_REMAINING=$(( (NEW_EXPIRES_AT - $(python3 -c "import time; print(int(time.time()*1000))")) / 3600000 ))

if [ "$NEW_EXPIRES_AT" -gt "$BEFORE_EXPIRY" ]; then
    echo "$(date -Iseconds) Token refreshed — now valid for ${NEW_REMAINING}h" >> "$LOG"
else
    echo "$(date -Iseconds) Claude Code ran but token expiry unchanged (${NEW_REMAINING}h remaining)" >> "$LOG"
fi

# Sync refreshed credentials to NanoClaw session dirs
cp "$CRED_FILE" /home/garrett/nanoclaw/data/sessions/telegram_main/.claude/.credentials.json 2>/dev/null
cp "$CRED_FILE" /home/garrett/nanoclaw/data/sessions/telegram_the-desk/.claude/.credentials.json 2>/dev/null

echo "$(date -Iseconds) Credential sync complete" >> "$LOG"
