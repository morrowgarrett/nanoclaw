# Audit Log

Log sensitive operations to a persistent audit trail.

## When to Log

- SSH commands to other machines
- File deletions or moves outside workspace
- Credential access or changes
- Relay triggers (start/stop)
- System configuration changes
- Any Tier 3 or Tier 4 action

## How to Log

Append to `/workspace/group/memory/audit.log`:

```bash
echo "$(date -Iseconds) action: description of what was done" >> /workspace/group/memory/audit.log
```

## Format

```
2026-03-28T09:30:00-05:00 ssh: connected to garrett@192.168.1.235 for tmux check
2026-03-28T09:31:00-05:00 relay: started relay on card-forecast project
2026-03-28T10:00:00-05:00 delete: removed stale container logs older than 7 days
```

## Reading the Log

```bash
# Last 20 entries
tail -20 /workspace/group/memory/audit.log

# Search for specific actions
grep "ssh:" /workspace/group/memory/audit.log
```
