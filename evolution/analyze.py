#!/usr/bin/env python3
"""
Trace Analyzer — identifies improvement opportunities from collected traces.

Reads: evolution/traces.json
Outputs: evolution/opportunities.json
"""
import json
import os
import re
from collections import Counter
from pathlib import Path

TRACES_FILE = os.path.join(os.path.dirname(__file__), "traces.json")
OUTPUT = os.path.join(os.path.dirname(__file__), "opportunities.json")


def analyze_task_failures(task_logs):
    """Find tasks that repeatedly fail."""
    failures = {}
    for log in task_logs:
        if log.get("run_status") == "error" or log.get("error"):
            task_id = log.get("id", "unknown")
            if task_id not in failures:
                failures[task_id] = {
                    "task_id": task_id,
                    "prompt": log.get("prompt", "")[:200],
                    "errors": [],
                    "count": 0,
                }
            failures[task_id]["errors"].append(log.get("error", "")[:200])
            failures[task_id]["count"] += 1

    return [
        {**f, "type": "recurring_failure", "priority": "high" if f["count"] > 2 else "medium"}
        for f in failures.values()
        if f["count"] > 1
    ]


def analyze_skill_candidates(conversations):
    """Find multi-step procedures that could become skills."""
    candidates = []
    for conv in conversations:
        content = conv.get("content", "")
        # Look for conversations with multiple tool uses (bash commands, file edits)
        bash_count = len(re.findall(r'```bash|curl |ssh |docker |git ', content))
        step_count = len(re.findall(r'step \d|Step \d|\d\.\s', content))

        if bash_count >= 3 or step_count >= 3:
            candidates.append({
                "type": "skill_candidate",
                "source": conv["file"],
                "date": conv["date"],
                "name": conv["name"],
                "bash_commands": bash_count,
                "steps": step_count,
                "priority": "medium",
                "reason": f"Multi-step procedure ({bash_count} commands, {step_count} steps)",
            })

    return candidates


def analyze_error_patterns(conversations):
    """Find repeated error patterns across conversations."""
    error_patterns = Counter()
    for conv in conversations:
        content = conv.get("content", "")
        errors = re.findall(r'(?:error|Error|ERROR|failed|Failed|FAILED)[:\s]+(.{20,80})', content)
        for err in errors:
            # Normalize the error
            normalized = re.sub(r'\d+', 'N', err.strip()[:60])
            error_patterns[normalized] += 1

    return [
        {
            "type": "error_pattern",
            "pattern": pattern,
            "count": count,
            "priority": "high" if count > 3 else "low",
        }
        for pattern, count in error_patterns.most_common(10)
        if count > 1
    ]


def main():
    if not os.path.exists(TRACES_FILE):
        print(f"No traces file at {TRACES_FILE}. Run collect_traces.py first.")
        return

    with open(TRACES_FILE) as f:
        traces = json.load(f)

    opportunities = {
        "analyzed_at": __import__("datetime").datetime.now().isoformat(),
        "task_failures": analyze_task_failures(traces.get("task_logs", [])),
        "skill_candidates": analyze_skill_candidates(traces.get("conversations", [])),
        "error_patterns": analyze_error_patterns(traces.get("conversations", [])),
    }

    total = (
        len(opportunities["task_failures"])
        + len(opportunities["skill_candidates"])
        + len(opportunities["error_patterns"])
    )

    with open(OUTPUT, "w") as f:
        json.dump(opportunities, f, indent=2)

    print(f"Found {total} improvement opportunities:")
    print(f"  - {len(opportunities['task_failures'])} recurring task failures")
    print(f"  - {len(opportunities['skill_candidates'])} skill candidates")
    print(f"  - {len(opportunities['error_patterns'])} error patterns")
    print(f"Output: {OUTPUT}")


if __name__ == "__main__":
    main()
