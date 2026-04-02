#!/usr/bin/env python3
"""
NanoClaw Self-Evolution Pipeline — orchestrates the full cycle.

Usage:
  python3 evolution/evolve.py              # Full pipeline
  python3 evolution/evolve.py --dry-run    # Analyze only, don't generate
  python3 evolution/evolve.py --apply      # Apply approved candidates to skills/
"""
import subprocess
import sys
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def run_step(name, script):
    print(f"\n{'='*60}")
    print(f"  {name}")
    print(f"{'='*60}\n")
    result = subprocess.run(
        [sys.executable, os.path.join(SCRIPT_DIR, script)],
        cwd=SCRIPT_DIR,
    )
    if result.returncode != 0:
        print(f"\n[!] {name} failed with exit code {result.returncode}")
        return False
    return True


def apply_candidates():
    """Copy approved candidate skills to the skills directory."""
    import json
    from pathlib import Path
    from shutil import copy2

    candidates_dir = os.path.join(SCRIPT_DIR, "candidates")
    manifest_path = os.path.join(candidates_dir, "manifest.json")
    skills_dir = os.path.expanduser("~/nanoclaw/groups/telegram_main/skills")

    if not os.path.exists(manifest_path):
        print("No candidates to apply.")
        return

    os.makedirs(skills_dir, exist_ok=True)

    with open(manifest_path) as f:
        manifest = json.load(f)

    applied = 0
    for candidate in manifest.get("candidates", []):
        if candidate["type"] == "skill" and os.path.exists(candidate["path"]):
            dest = os.path.join(skills_dir, os.path.basename(candidate["path"]))
            copy2(candidate["path"], dest)
            print(f"  Applied: {os.path.basename(candidate['path'])}")
            applied += 1

    print(f"\nApplied {applied} skill(s) to {skills_dir}")


def main():
    dry_run = "--dry-run" in sys.argv
    apply_only = "--apply" in sys.argv

    if apply_only:
        apply_candidates()
        return

    # Step 1: Collect traces
    if not run_step("Step 1: Collecting Traces", "collect_traces.py"):
        return

    # Step 2: Analyze
    if not run_step("Step 2: Analyzing Opportunities", "analyze.py"):
        return

    if dry_run:
        print("\n[Dry run] Stopping before generation.")
        return

    # Step 3: Generate candidates
    if not run_step("Step 3: Generating Candidates", "generate.py"):
        return

    print("\n" + "="*60)
    print("  Evolution cycle complete!")
    print("="*60)
    print("\nReview candidates in evolution/candidates/")
    print("To apply: python3 evolution/evolve.py --apply")


if __name__ == "__main__":
    main()
