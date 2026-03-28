#!/bin/bash
# SSHFS health check for Gear's workspace mount
# Runs via cron every 5 minutes. Remounts if stale.

MOUNT_POINT="/home/garrett/gear-workspace"
REMOTE="garrett@192.168.1.235:/home/garrett/.openclaw/workspace"
LOG="/home/garrett/nanoclaw/logs/sshfs-health.log"

# Quick read test with timeout
if timeout 3 ls "$MOUNT_POINT" > /dev/null 2>&1; then
    exit 0
fi

# Mount is stale or dead
echo "$(date -Iseconds) SSHFS stale — remounting" >> "$LOG"

# Force unmount stale fuse
fusermount3 -u "$MOUNT_POINT" 2>/dev/null

# Check if remote is reachable
if ! timeout 3 ssh -o BatchMode=yes -o ConnectTimeout=2 garrett@192.168.1.235 "echo ok" > /dev/null 2>&1; then
    echo "$(date -Iseconds) Surface Book unreachable — skipping remount" >> "$LOG"
    exit 0
fi

# Remount
sshfs "$REMOTE" "$MOUNT_POINT" -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,allow_other
if [ $? -eq 0 ]; then
    echo "$(date -Iseconds) SSHFS remounted successfully" >> "$LOG"
else
    echo "$(date -Iseconds) SSHFS remount failed" >> "$LOG"
fi
