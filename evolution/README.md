# NanoClaw Self-Evolution Pipeline

Inspired by Hermes Agent's GEPA (Genetic-Pareto) self-evolution system.
Reads execution traces, identifies improvement opportunities, and generates
skill/prompt variants for evaluation.

## Architecture

```
Execution Traces → Analysis → Candidate Generation → Evaluation → Application
     (logs)        (Python)      (Claude API)         (test)      (git commit)
```

## Components

1. **Trace Collector** (`collect_traces.py`) — Reads conversation archives from
   `/workspace/group/conversations/` and task run logs from the DB. Extracts
   patterns: what worked, what failed, what was slow.

2. **Analyzer** (`analyze.py`) — Identifies improvement opportunities:
   - Tasks that repeatedly fail
   - Patterns that could become skills
   - System prompt sections that cause confusion
   - Tool usage patterns that could be optimized

3. **Candidate Generator** (`generate.py`) — Uses Claude API to generate:
   - New skill files from successful multi-step procedures
   - Prompt refinements for the system prompt
   - Configuration adjustments

4. **Evaluator** (`evaluate.py`) — Tests candidates against historical traces
   to verify improvements without regression.

5. **Applicator** (`apply.py`) — Writes approved changes as commits to the fork.

## Usage

```bash
# Run the full pipeline
python3 evolution/evolve.py

# Run individual stages
python3 evolution/collect_traces.py
python3 evolution/analyze.py
python3 evolution/generate.py
```

## Cost

Approximately $2-10 per evolution cycle depending on trace volume.
Uses Claude Haiku for analysis, Sonnet for generation.
