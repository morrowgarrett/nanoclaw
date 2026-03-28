# Tmux Control

Remote-control tmux sessions via SSH. Send keystrokes, scrape output, wait for patterns.

## Finding Sessions

```bash
bash /workspace/skills/tmux/scripts/find-sessions.sh [host] [filter]
```

Lists tmux sessions. If `host` is provided, runs via SSH.

## Sending Commands

```bash
# Send a command to a tmux pane
tmux send-keys -t session:window.pane "your command here" Enter

# Via SSH
ssh user@host "tmux send-keys -t session:window.pane 'command' Enter"
```

## Reading Output

```bash
# Capture current pane content
tmux capture-pane -t session:window.pane -p | tail -20

# Via SSH
ssh user@host "tmux capture-pane -t mysession -p" | tail -20
```

## Waiting for Output

```bash
bash /workspace/skills/tmux/scripts/wait-for-text.sh <host> <session> <pattern> [timeout] [interval]
```

Polls a tmux pane until a regex pattern appears. Default timeout: 60s, interval: 2s.

## Examples

```bash
# List Gear's tmux sessions
ssh garrett@192.168.1.235 "tmux list-sessions" 2>/dev/null

# Watch a build on Gear
ssh garrett@192.168.1.235 "tmux capture-pane -t build -p" | tail -30

# Send a command to Gear's tmux
ssh garrett@192.168.1.235 "tmux send-keys -t main 'npm test' Enter"
```
