#!/usr/bin/env python3
"""
Trace Collector — reads conversation archives and task logs to build
a dataset for the evolution pipeline.

Outputs: evolution/traces.json
"""
import json
import os
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path

CONVERSATIONS_DIR = os.path.expanduser("~/nanoclaw/groups/telegram_main/conversations")
STORE_DB = os.path.expanduser("~/nanoclaw/store/messages.db")
SKILLS_DIR = os.path.expanduser("~/nanoclaw/groups/telegram_main/skills")
OUTPUT = os.path.join(os.path.dirname(__file__), "traces.json")


def collect_conversations(days=7):
    """Read recent conversation archives."""
    conversations = []
    cutoff = datetime.now() - timedelta(days=days)

    conv_dir = Path(CONVERSATIONS_DIR)
    if not conv_dir.exists():
        return conversations

    for f in sorted(conv_dir.glob("*.md")):
        try:
            date_str = f.name[:10]
            file_date = datetime.strptime(date_str, "%Y-%m-%d")
            if file_date < cutoff:
                continue
        except ValueError:
            continue

        content = f.read_text(errors="ignore")
        conversations.append({
            "file": str(f),
            "date": date_str,
            "name": f.stem,
            "content": content[:5000],  # Cap at 5K chars
            "length": len(content),
        })

    return conversations


def collect_task_logs():
    """Read scheduled task run logs from the DB."""
    if not os.path.exists(STORE_DB):
        return []

    db = sqlite3.connect(STORE_DB)
    db.row_factory = sqlite3.Row

    rows = db.execute("""
        SELECT t.id, t.prompt, t.schedule_value, t.status,
               l.run_at, l.duration_ms, l.status AS run_status, l.error
        FROM scheduled_tasks t
        LEFT JOIN task_run_logs l ON t.id = l.task_id
        ORDER BY l.run_at DESC
        LIMIT 50
    """).fetchall()

    logs = [dict(r) for r in rows]
    db.close()
    return logs


def collect_existing_skills():
    """List existing learned skills."""
    skills_dir = Path(SKILLS_DIR)
    if not skills_dir.exists():
        return []

    skills = []
    for f in skills_dir.glob("*.md"):
        skills.append({
            "file": str(f),
            "name": f.stem,
            "content": f.read_text(errors="ignore"),
        })
    return skills


def main():
    traces = {
        "collected_at": datetime.now().isoformat(),
        "conversations": collect_conversations(days=7),
        "task_logs": collect_task_logs(),
        "existing_skills": collect_existing_skills(),
    }

    with open(OUTPUT, "w") as f:
        json.dump(traces, f, indent=2, default=str)

    print(f"Collected {len(traces['conversations'])} conversations, "
          f"{len(traces['task_logs'])} task logs, "
          f"{len(traces['existing_skills'])} skills")
    print(f"Output: {OUTPUT}")


if __name__ == "__main__":
    main()
