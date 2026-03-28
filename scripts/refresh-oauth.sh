#!/bin/bash
# Refresh Claude OAuth token before it expires.
# Runs via cron every 4 hours.

CRED_FILE="$HOME/.claude/.credentials.json"
LOG="/home/garrett/nanoclaw/logs/oauth-refresh.log"

if [ ! -f "$CRED_FILE" ]; then
    echo "$(date -Iseconds) No credentials file found" >> "$LOG"
    exit 1
fi

# Extract refresh token and check expiry
REFRESH_TOKEN=$(python3 -c "import json; d=json.load(open('$CRED_FILE')); print(d.get('claudeAiOauth',{}).get('refreshToken',''))")
EXPIRES_AT=$(python3 -c "import json; d=json.load(open('$CRED_FILE')); print(d.get('claudeAiOauth',{}).get('expiresAt',0))")
NOW_MS=$(python3 -c "import time; print(int(time.time()*1000))")

if [ -z "$REFRESH_TOKEN" ]; then
    echo "$(date -Iseconds) No refresh token in credentials" >> "$LOG"
    exit 1
fi

# Check if token expires within 2 hours (7200000 ms)
REMAINING=$((EXPIRES_AT - NOW_MS))
if [ "$REMAINING" -gt 7200000 ]; then
    echo "$(date -Iseconds) Token still valid for $((REMAINING / 3600000))h — skipping refresh" >> "$LOG"
    exit 0
fi

echo "$(date -Iseconds) Token expires in $((REMAINING / 60000))m — refreshing" >> "$LOG"

# Call Claude's OAuth token refresh endpoint
RESPONSE=$(curl -s -X POST "https://platform.claude.com/v1/oauth/token" \
    -H "Content-Type: application/json" \
    -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"${REFRESH_TOKEN}\",\"client_id\":\"9d1c250a-e61b-44d9-88ed-5944d1962f5e\",\"scope\":\"user:inference user:profile user:sessions:claude_code user:mcp_servers user:file_upload\"}")

# Check for error
ERROR=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)
if [ -n "$ERROR" ] && [ "$ERROR" != "" ]; then
    echo "$(date -Iseconds) Refresh failed: $RESPONSE" >> "$LOG"
    exit 1
fi

# Extract new tokens
NEW_ACCESS=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null)
NEW_REFRESH=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('refresh_token',''))" 2>/dev/null)
NEW_EXPIRES_IN=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('expires_in',0))" 2>/dev/null)

if [ -z "$NEW_ACCESS" ] || [ "$NEW_ACCESS" = "" ]; then
    echo "$(date -Iseconds) No access token in response: $RESPONSE" >> "$LOG"
    exit 1
fi

# Calculate new expiry timestamp
NEW_EXPIRES_AT=$((NOW_MS + NEW_EXPIRES_IN * 1000))

# Update credentials file
python3 -c "
import json
with open('$CRED_FILE', 'r') as f:
    d = json.load(f)
d['claudeAiOauth']['accessToken'] = '$NEW_ACCESS'
if '$NEW_REFRESH':
    d['claudeAiOauth']['refreshToken'] = '$NEW_REFRESH'
d['claudeAiOauth']['expiresAt'] = $NEW_EXPIRES_AT
with open('$CRED_FILE', 'w') as f:
    json.dump(d, f, indent=2)
"

# Sync to NanoClaw session dirs
cp "$CRED_FILE" /home/garrett/nanoclaw/data/sessions/telegram_main/.claude/.credentials.json 2>/dev/null
cp "$CRED_FILE" /home/garrett/nanoclaw/data/sessions/telegram_the-desk/.claude/.credentials.json 2>/dev/null

echo "$(date -Iseconds) Token refreshed successfully, expires in $((NEW_EXPIRES_IN / 3600))h" >> "$LOG"
