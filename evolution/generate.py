#!/usr/bin/env python3
"""
Candidate Generator — uses Claude API to generate improvement candidates
from identified opportunities.

Reads: evolution/opportunities.json
Outputs: evolution/candidates/ directory with generated skill files and prompt patches
"""
import json
import os
import subprocess
from datetime import datetime
from pathlib import Path

OPPORTUNITIES_FILE = os.path.join(os.path.dirname(__file__), "opportunities.json")
CANDIDATES_DIR = os.path.join(os.path.dirname(__file__), "candidates")
SKILLS_DIR = os.path.expanduser("~/nanoclaw/groups/telegram_main/skills")


def call_claude(prompt, model="claude-haiku-4-5-20251001", max_tokens=1000):
    """Call Claude API via the credential proxy or directly."""
    import json as _json

    # Try credential proxy first (uses the oat token)
    token_file = os.path.expanduser("~/.claude/.credentials.json")
    if os.path.exists(token_file):
        with open(token_file) as f:
            creds = _json.load(f)
        token = creds.get("claudeAiOauth", {}).get("accessToken", "")
    else:
        return None

    result = subprocess.run(
        [
            "curl", "-s",
            "https://api.anthropic.com/v1/messages",
            "-H", f"Authorization: Bearer {token}",
            "-H", "anthropic-version: 2023-06-01",
            "-H", "anthropic-beta: oauth-2025-04-20",
            "-H", "Content-Type: application/json",
            "-d", _json.dumps({
                "model": model,
                "max_tokens": max_tokens,
                "messages": [{"role": "user", "content": prompt}],
            }),
        ],
        capture_output=True, text=True, timeout=30,
    )

    try:
        resp = _json.loads(result.stdout)
        if "content" in resp:
            return resp["content"][0]["text"]
        return None
    except Exception:
        return None


def generate_skill_from_candidate(candidate):
    """Use Claude to generate a skill file from a conversation trace."""
    prompt = f"""Based on this multi-step procedure from a conversation, write a concise skill file in markdown format.

Source: {candidate['name']} ({candidate['date']})
Reason: {candidate['reason']}

Write the skill as a markdown file with YAML frontmatter (name, description) followed by
clear step-by-step instructions. Keep it under 300 words. Include actual commands.

Respond with ONLY the markdown content, no explanation."""

    content = call_claude(prompt)
    if content:
        # Save to candidates dir
        filename = f"skill-{candidate['name'][:40]}.md"
        filepath = os.path.join(CANDIDATES_DIR, filename)
        with open(filepath, "w") as f:
            f.write(content)
        return filepath
    return None


def generate_fix_for_failure(failure):
    """Analyze a recurring failure and suggest a fix."""
    prompt = f"""A scheduled task keeps failing. Analyze and suggest a fix.

Task prompt (first 200 chars): {failure['prompt']}
Error count: {failure['count']}
Recent errors: {json.dumps(failure['errors'][:3])}

Suggest a concrete fix in under 100 words. Focus on the root cause."""

    content = call_claude(prompt)
    if content:
        filepath = os.path.join(CANDIDATES_DIR, f"fix-{failure['task_id'][:20]}.md")
        with open(filepath, "w") as f:
            f.write(f"# Fix for {failure['task_id']}\n\n{content}")
        return filepath
    return None


def main():
    if not os.path.exists(OPPORTUNITIES_FILE):
        print(f"No opportunities file. Run analyze.py first.")
        return

    os.makedirs(CANDIDATES_DIR, exist_ok=True)

    with open(OPPORTUNITIES_FILE) as f:
        opportunities = json.load(f)

    generated = []

    # Generate skills from candidates
    for candidate in opportunities.get("skill_candidates", [])[:5]:
        print(f"Generating skill from: {candidate['name']}")
        path = generate_skill_from_candidate(candidate)
        if path:
            generated.append({"type": "skill", "path": path})

    # Generate fixes for failures
    for failure in opportunities.get("task_failures", [])[:3]:
        print(f"Generating fix for: {failure['task_id'][:20]}")
        path = generate_fix_for_failure(failure)
        if path:
            generated.append({"type": "fix", "path": path})

    # Write manifest
    manifest = {
        "generated_at": datetime.now().isoformat(),
        "candidates": generated,
    }
    manifest_path = os.path.join(CANDIDATES_DIR, "manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"\nGenerated {len(generated)} candidates in {CANDIDATES_DIR}")


if __name__ == "__main__":
    main()
