#!/bin/bash
set -euo pipefail

# ============================================================
# Project Relay — Gear ↔ Clutch autonomous collaboration loop
#
# Gear  = openclaw on the NUC (192.168.1.235) — produces work
# Clutch = claude CLI on this host (ThinkPad)  — reviews work
#
# Usage:  ./relay.sh /path/to/project [max_rounds]
# Stop:   Send "STOP" in The Desk Telegram group, or: ./relay-stop.sh
#
# Requirements:
#   - Project dir with BRIEF.md
#   - SSH access to garrett@192.168.1.235
#   - claude CLI installed and authenticated on this host
#   - TELEGRAM_BOT_TOKEN in /home/garrett/nanoclaw/.env
# ============================================================

# ── Arguments ────────────────────────────────────────────────

PROJECT_DIR="${1:?Usage: relay.sh /path/to/project [max_rounds]}"
MAX_ROUNDS="${2:-10}"
COOLDOWN=60

# ── Configuration ────────────────────────────────────────────

NANOCLAW_DIR="/home/garrett/nanoclaw"
DESK_CHAT_ID="-5055447496"
DM_CHAT_ID="5996826656"

# Load env vars
TELEGRAM_TOKEN="$(grep '^TELEGRAM_BOT_TOKEN=' "$NANOCLAW_DIR/.env" | cut -d= -f2)"
MEMU_API_KEY="$(grep '^MEMU_API_KEY=' "$NANOCLAW_DIR/.env" | cut -d= -f2)"
export MEMU_API_KEY

# ── Validate inputs ─────────────────────────────────────────

if [ ! -d "$PROJECT_DIR" ]; then
    echo "Error: Project directory does not exist: $PROJECT_DIR"
    exit 1
fi

if [ ! -f "$PROJECT_DIR/BRIEF.md" ]; then
    echo "Error: No BRIEF.md found in $PROJECT_DIR"
    exit 1
fi

# Read the full brief content once
BRIEF_CONTENT="$(cat "$PROJECT_DIR/BRIEF.md")"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

# ── PID file for kill switch ─────────────────────────────────

mkdir -p "$NANOCLAW_DIR/data"
echo $$ > "$NANOCLAW_DIR/data/relay.pid"
trap 'rm -f "$NANOCLAW_DIR/data/relay.pid"' EXIT

# ── Initialize relay log ─────────────────────────────────────

RELAY_LOG="$PROJECT_DIR/RELAY.md"
cat > "$RELAY_LOG" << EOF
# Relay Log

**Project:** $PROJECT_NAME
**Brief:** $(head -1 "$PROJECT_DIR/BRIEF.md" | sed 's/^#\+\s*//')
**Started:** $(date -Iseconds)
**Max rounds:** $MAX_ROUNDS

---

EOF

echo "[relay] Started: $PROJECT_NAME — max $MAX_ROUNDS rounds"

# ============================================================
# Helper Functions
# ============================================================

# Send a message to The Desk via Telegram API.
# Uses MarkdownV2 parse mode. Caller must pre-escape if needed,
# or pass plain text (this function escapes common chars).
send_telegram() {
    local msg="$1"
    local parse_mode="${2:-}"
    local payload

    if [ -n "$parse_mode" ]; then
        payload=$(python3 -c "
import sys, json
msg = sys.stdin.read()
print(json.dumps({
    'chat_id': '$DESK_CHAT_ID',
    'text': msg,
    'parse_mode': '$parse_mode'
}))
" <<< "$msg")
    else
        payload=$(python3 -c "
import sys, json
msg = sys.stdin.read()
print(json.dumps({
    'chat_id': '$DESK_CHAT_ID',
    'text': msg
}))
" <<< "$msg")
    fi

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$payload" > /dev/null 2>&1 || true
}

# Check for STOP message in The Desk within the last 3 minutes.
# Returns 0 (true) if STOP was found.
check_stop() {
    local updates
    updates=$(curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getUpdates?offset=-10&limit=10" 2>/dev/null) || return 1

    local has_stop
    has_stop=$(python3 -c "
import sys, json, time
try:
    d = json.load(sys.stdin)
    now = time.time()
    for u in d.get('result', []):
        msg = u.get('message', {})
        chat_id = str(msg.get('chat', {}).get('id', ''))
        text = msg.get('text', '').upper().strip()
        ts = msg.get('date', 0)
        if chat_id == '$DESK_CHAT_ID' and text == 'STOP' and (now - ts) < 180:
            print('STOP')
            break
except:
    pass
" <<< "$updates" 2>/dev/null)

    [ "$has_stop" = "STOP" ]
}

# Call Gear via SSH to the NUC.
# Args: $1 = prompt text, $2 = output file path
call_gear() {
    local prompt="$1"
    local output_file="$2"

    # Write prompt to a temp file, then SSH it over and invoke openclaw
    local tmp_prompt
    tmp_prompt=$(mktemp /tmp/relay-gear-XXXXXX.txt)
    cat > "$tmp_prompt" << 'PROMPT_HEADER'
You are Gear, the production agent in a Relay loop with Clutch (your reviewer).
Produce thorough, complete work. Write your full deliverable in your response.
Do NOT ask questions — produce work product.

PROMPT_HEADER
    echo "$prompt" >> "$tmp_prompt"

    # Send via SSH. The prompt goes through stdin to avoid quoting issues.
    ssh -o ConnectTimeout=10 -o BatchMode=yes garrett@192.168.1.235 bash -s < <(
        cat << 'SSH_SCRIPT'
# Read the prompt from the heredoc that follows
PROMPT_FILE=$(mktemp /tmp/relay-prompt-XXXXXX.txt)
cat > "$PROMPT_FILE" << 'RELAY_PROMPT_DATA'
SSH_SCRIPT
        cat "$tmp_prompt"
        cat << 'SSH_SCRIPT_END'
RELAY_PROMPT_DATA
timeout 300 openclaw agent --agent main -m "$(cat "$PROMPT_FILE")" --local 2>/dev/null | grep -v '^\[agent'
rm -f "$PROMPT_FILE"
SSH_SCRIPT_END
    ) > "$output_file" 2>&1 || true

    rm -f "$tmp_prompt"
}

# Call Clutch via claude CLI on the host.
# Args: $1 = prompt text, $2 = output file path
call_clutch() {
    local prompt="$1"
    local output_file="$2"

    # claude --print runs a one-shot prompt, no interactive session
    claude --print -p "$prompt" 2>/dev/null > "$output_file" || true
}

# Use claude to generate a rich summary of the round for Telegram.
# This keeps the main script from needing complex text parsing.
# Args: $1 = round number, $2 = gear output file, $3 = clutch output file
generate_summary() {
    local round="$1"
    local gear_file="$2"
    local clutch_file="$3"

    local gear_text clutch_text
    gear_text="$(head -200 "$gear_file" 2>/dev/null || echo '(no output)')"
    clutch_text="$(head -200 "$clutch_file" 2>/dev/null || echo '(no output)')"

    # Count lines for context
    local gear_lines clutch_lines
    gear_lines="$(wc -l < "$gear_file" 2>/dev/null || echo 0)"
    clutch_lines="$(wc -l < "$clutch_file" 2>/dev/null || echo 0)"

    claude --print -p "You are summarizing a relay round for a Telegram notification. Be concise and specific.

PROJECT: $PROJECT_NAME
ROUND: $round/$MAX_ROUNDS

GEAR OUTPUT ($gear_lines lines total, first 200 shown):
$gear_text

CLUTCH REVIEW ($clutch_lines lines total, first 200 shown):
$clutch_text

Generate a Telegram notification in EXACTLY this format (plain text, use emoji as shown).
Fill in the bullet points with SPECIFIC details from the actual content — line counts, topics covered, key decisions, specific feedback items. Do NOT use generic placeholders.

Format:
---
Round $round/$MAX_ROUNDS — $PROJECT_NAME

GEAR output:
• (2-4 specific bullet points about what Gear produced)

CLUTCH review:
• (2-4 specific bullet points about Clutch's verdict and feedback)

Next round in 2 min. Send STOP in The Desk to cancel.
---

Output ONLY the notification text, nothing else. No markdown formatting, no code blocks." 2>/dev/null || echo "Round $round/$MAX_ROUNDS — $PROJECT_NAME complete. Check RELAY.md for details."
}

# Get usage/credential info for the summary
get_usage_info() {
    python3 -c "
import json, time
try:
    d = json.load(open('/home/garrett/.claude/.credentials.json'))
    oauth = d.get('claudeAiOauth', {})
    tier = oauth.get('rateLimitTier', 'unknown')
    exp = oauth.get('expiresAt', 0) / 1000
    remaining_h = max(0, (exp - time.time()) / 3600)
    print(f'tier {tier} | token valid {remaining_h:.1f}h')
except:
    print('usage info unavailable')
" 2>/dev/null
}

# ============================================================
# Main Relay Loop
# ============================================================

# Announce start
send_telegram "Project Relay Started
Project: $PROJECT_NAME
Brief: $(head -1 "$PROJECT_DIR/BRIEF.md" | sed 's/^#\+\s*//')
Max rounds: $MAX_ROUNDS, cooldown: ${COOLDOWN}s
Send STOP in The Desk to cancel."

# First round: Gear gets the brief and produces initial work
GEAR_PROMPT="PROJECT BRIEF:
$BRIEF_CONTENT

TASK: Read the brief above and produce your first comprehensive draft. Cover all areas mentioned in the brief with full detail. Be thorough — this is your initial work product that will be reviewed."

CLUTCH_FEEDBACK=""

for ROUND in $(seq 1 "$MAX_ROUNDS"); do
    echo "[relay] === Round $ROUND/$MAX_ROUNDS ==="

    # ── Step 1: Check for STOP ───────────────────────────────
    if check_stop; then
        send_telegram "Relay STOPPED by user at round $ROUND/$MAX_ROUNDS
Project: $PROJECT_NAME"
        echo "## STOPPED by user at round $ROUND" >> "$RELAY_LOG"
        echo "[relay] Stopped by user"
        exit 0
    fi

    # ── Step 2: Call Gear ────────────────────────────────────
    echo "[relay] Calling Gear..."
    GEAR_OUTPUT="$PROJECT_DIR/.gear-round-${ROUND}.txt"

    cat >> "$RELAY_LOG" << EOF

## Round $ROUND — $(date -Iseconds)

### Gear (Round $ROUND)

EOF

    call_gear "$GEAR_PROMPT" "$GEAR_OUTPUT"

    GEAR_RESPONSE="$(cat "$GEAR_OUTPUT" 2>/dev/null || echo '(Gear produced no output)')"
    GEAR_LINES="$(wc -l < "$GEAR_OUTPUT" 2>/dev/null || echo 0)"
    echo "[relay] Gear produced $GEAR_LINES lines"

    # Append Gear's full output to relay log
    echo '```' >> "$RELAY_LOG"
    cat "$GEAR_OUTPUT" >> "$RELAY_LOG" 2>/dev/null || true
    echo '```' >> "$RELAY_LOG"
    echo "" >> "$RELAY_LOG"

    # ── Step 3: Call Clutch to review ────────────────────────
    echo "[relay] Calling Clutch..."
    CLUTCH_OUTPUT="$PROJECT_DIR/.clutch-round-${ROUND}.txt"

    # Build the review prompt with brief + gear output
    CLUTCH_PROMPT="You are Clutch, the senior reviewer in a Relay loop. You review Gear's work against the project brief.

PROJECT BRIEF:
$BRIEF_CONTENT

GEAR'S OUTPUT FOR ROUND $ROUND ($GEAR_LINES lines):
$GEAR_RESPONSE

YOUR TASK:
Review Gear's work rigorously. Check for:
- Completeness against the brief requirements
- Technical accuracy and depth
- Scope drift from the original brief
- Risks, gaps, or assumptions that need verification
- Actionable improvements

END your review with exactly one of these verdicts on its own line:
  REVISION — if Gear needs to revise (list specific feedback)
  APPROVED — if the work fully meets all brief requirements with no further rounds needed
  ESCALATE — if Garrett's input is needed (explain why)

IMPORTANT: Use exactly ONE verdict word. Do NOT combine them (e.g. "APPROVED WITH NOTES" is not valid).
If the work is good but needs follow-up fixes, use REVISION — not a qualified APPROVED.
Only use APPROVED when the deliverable is truly complete and ready to ship.

Be specific. Reference exact sections. Do not be vague."

    echo "### Clutch Review (Round $ROUND)" >> "$RELAY_LOG"
    echo "" >> "$RELAY_LOG"

    call_clutch "$CLUTCH_PROMPT" "$CLUTCH_OUTPUT"

    CLUTCH_RESPONSE="$(cat "$CLUTCH_OUTPUT" 2>/dev/null || echo '(Clutch produced no output)')"
    CLUTCH_LINES="$(wc -l < "$CLUTCH_OUTPUT" 2>/dev/null || echo 0)"
    echo "[relay] Clutch produced $CLUTCH_LINES lines"

    # Append Clutch's full output to relay log
    echo '```' >> "$RELAY_LOG"
    cat "$CLUTCH_OUTPUT" >> "$RELAY_LOG" 2>/dev/null || true
    echo '```' >> "$RELAY_LOG"
    echo "" >> "$RELAY_LOG"
    echo "---" >> "$RELAY_LOG"

    # ── Step 4: Generate and post rich Telegram summary ──────
    echo "[relay] Generating summary..."
    USAGE="$(get_usage_info)"
    SUMMARY="$(generate_summary "$ROUND" "$GEAR_OUTPUT" "$CLUTCH_OUTPUT")"

    # Append usage info
    SUMMARY="$SUMMARY
Usage: $USAGE"

    send_telegram "$SUMMARY"
    echo "[relay] Posted summary to The Desk"

    # ── Step 5: Check for completion signals ─────────────────
    # Order matters: ESCALATE > REVISION > APPROVED.
    # "APPROVED WITH NOTES" previously matched APPROVED and killed the loop.
    # Now we check ESCALATE first, then REVISION, then require a clean APPROVED
    # (the word APPROVED not immediately followed by qualifiers like "WITH").
    # Changed 2026-03-27: fix relay stall caused by premature APPROVED match.

    if echo "$CLUTCH_RESPONSE" | grep -qiw "ESCALATE"; then
        ESCALATE_REASON="$(echo "$CLUTCH_RESPONSE" | grep -iA5 "ESCALATE" | head -6)"
        send_telegram "ESCALATION at round $ROUND/$MAX_ROUNDS
Project: $PROJECT_NAME
Reason: $ESCALATE_REASON
Relay paused. Address the escalation and re-run to continue."
        echo "## ESCALATED at round $ROUND" >> "$RELAY_LOG"
        echo "[relay] ESCALATED — exiting"
        exit 0
    fi

    if echo "$CLUTCH_RESPONSE" | grep -qiw "REVISION"; then
        echo "[relay] REVISION — continuing to next round"
        # Fall through to prepare next round prompt
    elif echo "$CLUTCH_RESPONSE" | grep -qiP '(?i)\bAPPROVED\b(?!\s+WITH)'; then
        send_telegram "Project APPROVED by Clutch at round $ROUND/$MAX_ROUNDS
Project: $PROJECT_NAME
Review the deliverables in the project folder."
        echo "## APPROVED at round $ROUND" >> "$RELAY_LOG"
        echo "[relay] APPROVED — exiting"
        exit 0
    else
        echo "[relay] No clear verdict detected — treating as REVISION"
    fi

    # ── Step 6: Prepare next round prompt ────────────────────
    # Include the brief, Clutch's feedback, and instruction to revise
    GEAR_PROMPT="PROJECT BRIEF:
$BRIEF_CONTENT

CLUTCH'S REVIEW OF YOUR PREVIOUS ROUND ($ROUND):
$CLUTCH_RESPONSE

TASK: Address ALL of Clutch's feedback points above. Produce a revised, complete work product.
Do not just describe changes — produce the full updated deliverable.
Be thorough and address every specific point raised."

    # ── Step 7: Cooldown ─────────────────────────────────────
    if [ "$ROUND" -lt "$MAX_ROUNDS" ]; then
        echo "[relay] Cooling down for ${COOLDOWN}s..."
        sleep "$COOLDOWN"
    fi
done

# ── Max rounds exhausted ─────────────────────────────────────

send_telegram "Relay reached max rounds ($MAX_ROUNDS)
Project: $PROJECT_NAME
Review progress in RELAY.md. Re-run to continue."
echo "## MAX ROUNDS reached ($MAX_ROUNDS)" >> "$RELAY_LOG"
echo "[relay] Max rounds reached — exiting"
