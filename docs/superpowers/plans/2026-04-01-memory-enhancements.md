# Memory Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add six memory enhancements inspired by Claude Code's leaked architecture to NanoClaw's memU system — memory-as-hint prompting, three-tier memory discipline, autoDream consolidation, pre-compact context saving, persistent verification mode, and confidence decay.

**Architecture:** All changes are additive. The memU sidecar gets three new endpoints (`/briefing`, `/dream`, `/dream-status`). The agent-runner gets briefing injection at session start and enhanced pre-compact saving. Confidence is stored in the existing `extra` JSON column (no schema migration). CLAUDE.md files get memory discipline instructions. A new `dream.py` script runs via cron for background consolidation.

**Tech Stack:** Python (FastAPI, SQLAlchemy), TypeScript (Claude Agent SDK), PostgreSQL/pgvector, Ollama (qwen3:0.6b), bash (cron)

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `groups/global/CLAUDE.md` | Modify | Memory-as-hint instructions, three-tier explanation |
| `memu-framework/sidecar.py` | Modify | `/briefing`, `/dream`, `/dream-status` endpoints, confidence in `/memorize` and `/retrieve` |
| `memu-framework/dream.py` | Create | autoDream consolidation script |
| `scripts/dream-cron.sh` | Create | Cron wrapper for dream.py |
| `container/agent-runner/src/index.ts` | Modify | Briefing injection at session start, pre-compact memU push |

---

### Task 1: Memory-as-Hint Instructions in CLAUDE.md

**Files:**
- Modify: `groups/global/CLAUDE.md:99-133` (Memory section)

- [ ] **Step 1: Add Memory Discipline section to global CLAUDE.md**

Insert after the existing "## Memory" section header (line 99), before "The `conversations/` folder" (line 101):

```markdown
### Memory Discipline

memU results are hints, not ground truth. Before acting on any recalled memory:
1. **Verify against current state** — read the file, check the service, grep the code
2. **Prefer what you observe now** — if memory conflicts with reality, trust reality
3. **Flag stale memories** — if you discover a memory is wrong, note it so it can be corrected

This applies to the briefing file, memU retrieval results, and conversation archives. Memory tells you where to look; verification tells you what's true.

### Three-Tier Memory

Your memory operates in three tiers:
- **Tier 1 (always loaded):** `MEMORY_BRIEFING.md` in your workspace — top 25 memories by relevance, refreshed each session. Read this at the start of complex tasks.
- **Tier 2 (on-demand):** Full memU knowledge graph via `/retrieve`. Query when you need deeper context.
- **Tier 3 (search-only):** Conversation archives in `conversations/`. Grep for specific details, never bulk-load.

Start with Tier 1. Escalate to Tier 2 when the briefing doesn't cover it. Drop to Tier 3 only for historical details.
```

- [ ] **Step 2: Verify the file reads correctly**

Run: `head -140 groups/global/CLAUDE.md`
Expected: New sections visible between "## Memory" and the conversations paragraph.

- [ ] **Step 3: Commit**

```bash
git add groups/global/CLAUDE.md
git commit -m "feat: add memory-as-hint discipline and three-tier instructions to CLAUDE.md"
```

---

### Task 2: Confidence Decay in memU Sidecar

**Files:**
- Modify: `memu-framework/sidecar.py` (memorize and retrieve endpoints)
- Modify: `memu-framework/src/memu/database/postgres/repositories/memory_item_repo.py` (salience scoring)

- [ ] **Step 1: Add confidence to the `/memorize` endpoint**

In `sidecar.py`, modify the `MemorizeRequest` model to accept optional confidence and memory_class:

```python
class MemorizeRequest(BaseModel):
    content: str
    modality: str = "conversation"
    agent_source: str = "nanoclaw"
    metadata: dict = {}
    confidence: float = 0.8
    memory_class: str = "knowledge"  # permanent, knowledge, context, progress
```

In the `/memorize` endpoint, after creating the new item (the `await service.create_memory_item(...)` call around line 174), update the item's `extra` dict to include confidence and memory_class:

```python
    # Set confidence and memory_class in extra
    if item and item.get("id"):
        try:
            with service.database._sessions.session() as session:
                from sqlalchemy import text as sa_text
                current_extra = session.execute(
                    sa_text("SELECT extra FROM memory_items WHERE id = :id"),
                    {"id": item["id"]},
                ).scalar() or {}
                updated_extra = {
                    **current_extra,
                    "confidence": req.confidence,
                    "memory_class": req.memory_class,
                }
                session.execute(
                    sa_text(
                        "UPDATE memory_items SET extra = :extra WHERE id = :id"
                    ),
                    {"extra": json.dumps(updated_extra), "id": item["id"]},
                )
                session.commit()
        except Exception as e:
            print(f"Warning: could not set confidence: {e}")
```

Add `import json` at the top of sidecar.py.

Also update the existing "update existing" branch (around line 157) to preserve/boost confidence:

```python
            session.execute(
                sa_text(
                    "UPDATE memory_items SET summary = :summary, "
                    "embedding = :vec, updated_at = NOW(), "
                    "extra = extra || :new_extra "
                    "WHERE id = :id"
                ),
                {
                    "summary": req.content,
                    "vec": vec_str,
                    "id": existing[0],
                    "new_extra": json.dumps({
                        "confidence": min(1.0, req.confidence + 0.05),
                        "memory_class": req.memory_class,
                    }),
                },
            )
```

- [ ] **Step 2: Add confidence decay to salience scoring**

In `memory_item_repo.py`, modify `_salience_score` to factor in confidence with half-life decay:

```python
    MEMORY_CLASS_HALF_LIFE = {
        "permanent": None,    # No decay
        "knowledge": 90.0,    # 90-day half-life
        "context": 30.0,      # 30-day half-life
        "progress": 7.0,      # 7-day half-life
    }

    @staticmethod
    def _salience_score(
        similarity: float,
        reinforcement_count: int,
        last_reinforced_at: datetime | None,
        recency_decay_days: float,
        confidence: float = 0.8,
        memory_class: str = "knowledge",
    ) -> float:
        """Compute salience score: similarity * reinforcement * recency * confidence."""
        reinforcement_factor = math.log(reinforcement_count + 1)

        if last_reinforced_at is None:
            recency_factor = 0.5
        else:
            now = datetime.now(last_reinforced_at.tzinfo) if last_reinforced_at.tzinfo else datetime.utcnow()
            days_ago = (now - last_reinforced_at).total_seconds() / 86400
            recency_factor = math.exp(-0.693 * days_ago / recency_decay_days)

        # Apply confidence decay based on memory class
        half_life = PostgresMemoryItemRepo.MEMORY_CLASS_HALF_LIFE.get(memory_class)
        if half_life is not None and last_reinforced_at is not None:
            now = datetime.now(last_reinforced_at.tzinfo) if last_reinforced_at.tzinfo else datetime.utcnow()
            days_ago = (now - last_reinforced_at).total_seconds() / 86400
            confidence = confidence * math.exp(-0.693 * days_ago / half_life)

        return similarity * reinforcement_factor * recency_factor * max(confidence, 0.01)
```

Update `_vector_search_local` to pass confidence and memory_class from the item's extra dict:

```python
            if ranking == "salience":
                extra = item.extra or {}
                reinforcement_count = extra.get("reinforcement_count", 1)
                last_reinforced_at = self._parse_datetime(extra.get("last_reinforced_at"))
                confidence = extra.get("confidence", 0.8)
                memory_class = extra.get("memory_class", "knowledge")
                score = self._salience_score(
                    similarity,
                    reinforcement_count,
                    last_reinforced_at,
                    recency_decay_days,
                    confidence,
                    memory_class,
                )
```

- [ ] **Step 3: Add confidence to `/retrieve` response**

In `sidecar.py`, modify the retrieve endpoint's response to include confidence from the extra dict. In the items list comprehension (around line 293):

```python
        items = [
            {
                "id": item["id"],
                "content": item["summary"],
                "summary": item["summary"],
                "memory_type": item["memory_type"],
                "extra": item["extra"],
                "created_at": item["created_at"],
                "score": item["score"],
                "distance": item.get("distance"),
                "confidence": item.get("extra", {}).get("confidence", 0.8),
                "memory_class": item.get("extra", {}).get("memory_class", "knowledge"),
            }
            for item in results
        ]
```

- [ ] **Step 4: Test confidence defaults with existing memories**

Run: `curl -s -X POST http://localhost:8100/retrieve -H "X-API-Key: $MEMU_API_KEY" -H "Content-Type: application/json" -d '{"query": "test", "limit": 3}' | python3 -m json.tool`
Expected: Existing memories return with `confidence: 0.8` default and `memory_class: "knowledge"` default.

- [ ] **Step 5: Commit**

```bash
git add memu-framework/sidecar.py memu-framework/src/memu/database/postgres/repositories/memory_item_repo.py
git commit -m "feat: add confidence decay and memory_class to memU salience scoring"
```

---

### Task 3: Briefing Endpoint and Session Injection (Three-Tier)

**Files:**
- Modify: `memu-framework/sidecar.py` (new `/briefing` endpoint)
- Modify: `container/agent-runner/src/index.ts` (fetch briefing at session start)

- [ ] **Step 1: Add `/briefing` endpoint to sidecar**

In `sidecar.py`, add after the `/memory/stats` endpoint:

```python
@app.get("/briefing")
async def briefing(limit: int = 25):
    """Return top-N memories ranked by salience as a compact briefing.
    This powers Tier 1 of the three-tier memory discipline."""
    from sqlalchemy import text as sa_text

    with service.database._sessions.session() as session:
        # Get memories with embeddings, ordered by a composite score:
        # reinforcement * recency * confidence
        rows = session.execute(
            sa_text("""
                SELECT id, summary, memory_type,
                       extra,
                       created_at,
                       updated_at
                FROM memory_items
                WHERE embedding IS NOT NULL
                ORDER BY updated_at DESC
                LIMIT :lim
            """),
            {"lim": limit * 3},  # Overfetch to rank in Python
        ).fetchall()

    import math
    from datetime import datetime, timezone

    now = datetime.now(timezone.utc)
    scored = []
    for r in rows:
        extra = r[3] or {}
        reinforcement = extra.get("reinforcement_count", 1)
        confidence = extra.get("confidence", 0.8)
        memory_class = extra.get("memory_class", "knowledge")

        # Recency from updated_at
        updated = r[5]
        if updated and hasattr(updated, 'timestamp'):
            days_ago = (now - updated.replace(tzinfo=timezone.utc)).total_seconds() / 86400
        else:
            days_ago = 30.0

        recency = math.exp(-0.693 * days_ago / 30.0)

        # Confidence decay by class
        half_lives = {"permanent": None, "knowledge": 90.0, "context": 30.0, "progress": 7.0}
        hl = half_lives.get(memory_class)
        effective_conf = confidence
        if hl is not None:
            effective_conf = confidence * math.exp(-0.693 * days_ago / hl)

        score = math.log(reinforcement + 1) * recency * max(effective_conf, 0.01)
        scored.append({
            "summary": r[1],
            "memory_type": r[2],
            "confidence": round(effective_conf, 2),
            "memory_class": memory_class,
            "score": round(score, 4),
        })

    scored.sort(key=lambda x: x["score"], reverse=True)
    top = scored[:limit]

    # Format as compact briefing text
    lines = ["# Memory Briefing", "", "Top memories by salience (verify before acting):", ""]
    for item in top:
        conf_tag = f"[{item['memory_class']}:{item['confidence']:.0%}]"
        lines.append(f"- {conf_tag} {item['summary']}")

    return {
        "briefing_text": "\n".join(lines),
        "count": len(top),
        "items": top,
    }
```

- [ ] **Step 2: Inject briefing at session start in agent-runner**

In `container/agent-runner/src/index.ts`, modify the existing memU snapshot block (around line 456-478) to also fetch and write the briefing file:

Replace the existing memU snapshot block with:

```typescript
  // Fetch memU briefing (Tier 1) and query-specific memories (Tier 2 preview)
  let memorySnapshot = '';
  const memuUrl = process.env.MEMU_SIDECAR_URL;
  const memuKey = process.env.MEMU_API_KEY;
  if (memuUrl && memuKey) {
    // Tier 1: Write briefing file for persistent reference
    try {
      const briefingResp = execSyncSafe(
        `curl -s --connect-timeout 3 --max-time 5 "${memuUrl}/briefing?limit=25" ` +
          `-H "X-API-Key: ${memuKey}"`,
      );
      if (briefingResp) {
        const briefing = JSON.parse(briefingResp);
        if (briefing.briefing_text) {
          const briefingPath = '/workspace/group/MEMORY_BRIEFING.md';
          fs.writeFileSync(briefingPath, briefing.briefing_text);
          log(`Wrote memory briefing (${briefing.count} items) to ${briefingPath}`);
        }
      }
    } catch { /* briefing unavailable */ }

    // Tier 2 preview: query-relevant memories injected into system prompt
    try {
      const query = containerInput.prompt.slice(0, 200).replace(/'/g, '');
      const resp = execSyncSafe(
        `curl -s --connect-timeout 3 --max-time 5 -X POST "${memuUrl}/retrieve" ` +
          `-H "X-API-Key: ${memuKey}" -H "Content-Type: application/json" ` +
          `-d '${JSON.stringify({ query, top_k: 5 })}'`,
      );
      if (resp) {
        const memories = JSON.parse(resp);
        const items = memories.items || memories;
        if (Array.isArray(items) && items.length > 0) {
          memorySnapshot = '\n\n## Recalled Memories (verify before acting)\n' +
            items.map((m: { content?: string; summary?: string; confidence?: number; memory_class?: string }) => {
              const conf = m.confidence ?? 0.8;
              const cls = m.memory_class ?? 'knowledge';
              return `- [${cls}:${Math.round(conf * 100)}%] ${(m.content || m.summary || '').slice(0, 500)}`;
            }).join('\n');
          log(`Loaded ${items.length} memories from memU`);
        }
      }
    } catch { /* memU unavailable */ }
  }
```

- [ ] **Step 3: Verify briefing endpoint works**

Run: `curl -s http://localhost:8100/briefing?limit=5 -H "X-API-Key: $MEMU_API_KEY" | python3 -m json.tool`
Expected: JSON with `briefing_text`, `count`, and `items` array.

- [ ] **Step 4: Commit**

```bash
git add memu-framework/sidecar.py container/agent-runner/src/index.ts
git commit -m "feat: add /briefing endpoint and three-tier memory injection at session start"
```

---

### Task 4: Pre-Compact Context Saving to memU

**Files:**
- Modify: `container/agent-runner/src/index.ts` (extend `createPreCompactHook`)

- [ ] **Step 1: Add memU push to pre-compact hook**

In `container/agent-runner/src/index.ts`, inside `createPreCompactHook`, after the existing transcript archiving logic (after the `log('Archived conversation to ${filePath}')` line, around line 209), add:

```typescript
      // Push session context to memU before compaction
      const memuUrl = process.env.MEMU_SIDECAR_URL;
      const memuKey = process.env.MEMU_API_KEY;
      if (memuUrl && memuKey && messages.length > 0) {
        try {
          // Extract key context: first user message (topic) + last few exchanges
          const topic = messages.find(m => m.role === 'user')?.content.slice(0, 200) || 'unknown';
          const recentMessages = messages.slice(-6);
          const contextSummary = [
            `Session topic: ${topic}`,
            `Messages exchanged: ${messages.length}`,
            summary ? `Summary: ${summary}` : '',
            `Recent context: ${recentMessages.map(m => `${m.role}: ${m.content.slice(0, 100)}`).join(' | ')}`,
          ].filter(Boolean).join('. ');

          execSyncSafe(
            `curl -s --connect-timeout 3 --max-time 5 -X POST "${memuUrl}/memorize" ` +
              `-H "X-API-Key: ${memuKey}" -H "Content-Type: application/json" ` +
              `-d ${JSON.stringify(JSON.stringify({
                content: `Pre-compaction snapshot (${date}): ${contextSummary}`,
                agent_source: 'nanoclaw',
                confidence: 0.6,
                memory_class: 'context',
              }))}`,
          );
          log('Pushed pre-compaction context to memU');
        } catch {
          log('Failed to push pre-compaction context to memU');
        }
      }
```

- [ ] **Step 2: Verify hook still compiles**

Run: `cd ~/nanoclaw && npm run build`
Expected: No TypeScript errors.

- [ ] **Step 3: Commit**

```bash
git add container/agent-runner/src/index.ts
git commit -m "feat: push session context to memU before compaction"
```

---

### Task 5: Persistent Verification (Ralph Pattern)

**Files:**
- Modify: `container/agent-runner/src/index.ts` (add completion detection)
- Modify: `src/container-runner.ts` (add hook config to generated settings.json)

- [ ] **Step 1: Add verification prompt injection to agent-runner**

In `container/agent-runner/src/index.ts`, add a new function after `createPreCompactHook`:

```typescript
/**
 * Detect premature completion claims and inject a verification prompt.
 * Inspired by Claude Code's "Ralph" persistent verification pattern.
 */
function createVerificationHook(): (response: string) => string | null {
  const COMPLETION_PATTERNS = [
    /\b(?:done|finished|complete[d]?|implemented|all set|that'?s it)\b/i,
    /\b(?:everything is|changes are|updates are|fix is)[\s\w]*(?:done|complete|in place|ready)\b/i,
  ];

  let verificationRequested = false;

  return (response: string) => {
    // Only trigger once per session to avoid loops
    if (verificationRequested) return null;

    // Check if the response contains completion language
    const hasCompletion = COMPLETION_PATTERNS.some(p => p.test(response));
    if (!hasCompletion) return null;

    // Check if the response also contains verification evidence
    // (test output, command results, file contents) — if so, already verified
    const hasEvidence = /(?:PASS|FAIL|✓|✗|exit code|output:|result:|\$ |```)/i.test(response);
    if (hasEvidence) return null;

    verificationRequested = true;
    return (
      '\n\n<system-reminder>VERIFICATION REQUIRED: You claimed this work is complete. ' +
      'Before finishing, verify by running the relevant command, test, or check. ' +
      'Show the actual output. Do not claim completion without evidence.</system-reminder>'
    );
  };
}
```

Then in the `runQuery` function, before the `for await` loop (around line 532), create the verification hook:

```typescript
  const verifyHook = createVerificationHook();
```

Inside the `for await` loop, after the result handling block (around line 640-651), add:

```typescript
    if (message.type === 'assistant' && 'message' in message) {
      const msg = message as { message?: { content?: Array<{ type: string; text?: string }> } };
      const textParts = msg.message?.content?.filter(c => c.type === 'text').map(c => c.text || '') || [];
      const fullText = textParts.join('');
      const verification = verifyHook(fullText);
      if (verification && !closedDuringQuery) {
        log('Verification hook triggered — injecting verification prompt');
        stream.push(verification);
      }
    }
```

- [ ] **Step 2: Verify the build**

Run: `cd ~/nanoclaw && npm run build`
Expected: No TypeScript errors.

- [ ] **Step 3: Commit**

```bash
git add container/agent-runner/src/index.ts
git commit -m "feat: add Ralph-pattern persistent verification hook"
```

---

### Task 6: autoDream Consolidation Script

**Files:**
- Create: `memu-framework/dream.py`
- Create: `scripts/dream-cron.sh`
- Modify: `memu-framework/sidecar.py` (add `/dream` and `/dream-status` endpoints)

- [ ] **Step 1: Add dream status and trigger endpoints to sidecar**

In `sidecar.py`, add:

```python
import json
from pathlib import Path

DREAM_STATUS_FILE = Path("/tmp/memu-dream-status.json")


@app.get("/dream-status")
async def dream_status():
    """Check when the last dream ran and how many memorize calls since."""
    if DREAM_STATUS_FILE.exists():
        status = json.loads(DREAM_STATUS_FILE.read_text())
    else:
        status = {"last_dream": None, "memorize_since": 0}
    return status


@app.post("/dream")
async def trigger_dream():
    """Trigger a dream consolidation cycle (called by cron)."""
    import subprocess
    dream_script = Path(__file__).parent / "dream.py"
    if not dream_script.exists():
        return {"status": "error", "detail": "dream.py not found"}
    # Run asynchronously so the endpoint returns immediately
    subprocess.Popen(
        ["python3", str(dream_script)],
        env={**dict(os.environ)},
        stdout=open("/tmp/dream-stdout.log", "w"),
        stderr=open("/tmp/dream-stderr.log", "w"),
    )
    return {"status": "started"}
```

Also increment `memorize_since` counter in the `/memorize` endpoint. Add this at the end of the memorize function, before the final return:

```python
    # Track memorize calls for dream gate
    try:
        status = json.loads(DREAM_STATUS_FILE.read_text()) if DREAM_STATUS_FILE.exists() else {}
        status["memorize_since"] = status.get("memorize_since", 0) + 1
        DREAM_STATUS_FILE.write_text(json.dumps(status))
    except Exception:
        pass
```

- [ ] **Step 2: Create dream.py consolidation script**

Create `memu-framework/dream.py`:

```python
#!/usr/bin/env python3
"""
autoDream — Memory consolidation for memU.
Inspired by Claude Code's leaked autoDream architecture.

Runs as a background process triggered by cron (3:30 AM daily).
Three gates must pass: 24h since last dream, 5+ memorize calls, lock acquired.

Four phases:
  1. Orient — load all memories, build baseline
  2. Gather — identify clusters of similar memories
  3. Consolidate — merge duplicates, resolve contradictions via LLM
  4. Prune — remove low-confidence memories, update dream status
"""

import fcntl
import json
import math
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests

SIDECAR_URL = os.environ.get("MEMU_SIDECAR_URL", "http://localhost:8100")
API_KEY = os.environ["MEMU_API_KEY"]
OLLAMA_URL = os.environ.get("OLLAMA_BASE_URL", "http://localhost:11434")
CHAT_MODEL = os.environ.get("DREAM_CHAT_MODEL", "qwen3:0.6b")
LOCK_FILE = Path("/tmp/memu-dream.lock")
STATUS_FILE = Path("/tmp/memu-dream-status.json")
LOG_DIR = Path(os.environ.get("DREAM_LOG_DIR", "/tmp"))

HEADERS = {"X-API-Key": API_KEY, "Content-Type": "application/json"}

# Gate thresholds
MIN_HOURS_SINCE_LAST = 24
MIN_MEMORIZE_CALLS = 5
CONFIDENCE_PRUNE_THRESHOLD = 0.15  # After decay, prune below this


def log(msg: str) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[dream {ts}] {msg}", flush=True)


def check_gates() -> bool:
    """Check all three gates. Return True if dream should proceed."""
    status = json.loads(STATUS_FILE.read_text()) if STATUS_FILE.exists() else {}

    # Gate 1: Time since last dream
    last = status.get("last_dream")
    if last:
        hours_ago = (time.time() - last) / 3600
        if hours_ago < MIN_HOURS_SINCE_LAST:
            log(f"Gate 1 FAIL: only {hours_ago:.1f}h since last dream (need {MIN_HOURS_SINCE_LAST})")
            return False
    log("Gate 1 PASS: time threshold met")

    # Gate 2: Memorize calls since last dream
    calls = status.get("memorize_since", 0)
    if calls < MIN_MEMORIZE_CALLS:
        log(f"Gate 2 FAIL: only {calls} memorize calls (need {MIN_MEMORIZE_CALLS})")
        return False
    log(f"Gate 2 PASS: {calls} memorize calls")

    # Gate 3: Lock (checked in main)
    return True


def fetch_all_memories() -> list[dict]:
    """Fetch all memories from memU."""
    resp = requests.get(f"{SIDECAR_URL}/memory/items", headers=HEADERS, timeout=30)
    resp.raise_for_status()
    data = resp.json()
    items = data.get("items", data)
    if isinstance(items, dict):
        return list(items.values())
    return items


def cosine_sim(a: list[float], b: list[float]) -> float:
    if not a or not b:
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb + 1e-9)


def find_clusters(memories: list[dict], threshold: float = 0.85) -> list[list[dict]]:
    """Group memories by embedding similarity."""
    used = set()
    clusters = []
    for i, a in enumerate(memories):
        if i in used or not a.get("embedding"):
            continue
        cluster = [a]
        used.add(i)
        for j, b in enumerate(memories):
            if j in used or not b.get("embedding"):
                continue
            if cosine_sim(a["embedding"], b["embedding"]) > threshold:
                cluster.append(b)
                used.add(j)
        if len(cluster) > 1:
            clusters.append(cluster)
    return clusters


def consolidate_cluster(cluster: list[dict]) -> str | None:
    """Use LLM to merge a cluster of similar memories into one."""
    summaries = [m.get("summary", "") for m in cluster]
    prompt = (
        "You are a memory consolidation agent. Below are similar memories that may be "
        "duplicates or contain contradictions. Merge them into a single, accurate memory. "
        "Prefer the most recent information when facts conflict. "
        "Convert any relative dates to absolute dates based on today's date. "
        "Output ONLY the consolidated memory text, nothing else.\n\n"
        f"Today's date: {datetime.now().strftime('%Y-%m-%d')}\n\n"
        "Memories to consolidate:\n"
    )
    for i, s in enumerate(summaries, 1):
        prompt += f"{i}. {s}\n"

    # Strip /v1 suffix if present for Ollama chat endpoint
    base = OLLAMA_URL.rstrip("/")
    if base.endswith("/v1"):
        base = base[:-3]

    try:
        resp = requests.post(
            f"{base}/api/chat",
            json={
                "model": CHAT_MODEL,
                "messages": [{"role": "user", "content": prompt}],
                "stream": False,
            },
            timeout=60,
        )
        resp.raise_for_status()
        content = resp.json().get("message", {}).get("content", "")
        # Strip <think>...</think> tags if present (qwen3 thinking mode)
        import re
        content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
        return content if content else None
    except Exception as e:
        log(f"LLM consolidation failed: {e}")
        return None


def delete_memory(item_id: str) -> None:
    requests.delete(f"{SIDECAR_URL}/memory/items/{item_id}", headers=HEADERS, timeout=10)


def store_memory(content: str, confidence: float = 0.85, memory_class: str = "knowledge") -> None:
    requests.post(
        f"{SIDECAR_URL}/memorize",
        headers=HEADERS,
        json={
            "content": content,
            "agent_source": "nanoclaw",
            "confidence": confidence,
            "memory_class": memory_class,
        },
        timeout=10,
    )


def main() -> None:
    log("autoDream starting")

    # Gate check
    if not check_gates():
        log("Gates not met, exiting")
        return

    # Gate 3: Lock
    lock_fd = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("Gate 3 FAIL: another dream is running")
        return
    log("Gate 3 PASS: lock acquired")

    dream_log = []

    try:
        # Phase 1: Orient
        log("Phase 1: Orient — loading all memories")
        memories = fetch_all_memories()
        log(f"  Loaded {len(memories)} memories")
        if len(memories) < 2:
            log("Not enough memories to consolidate")
            return

        # Phase 2: Gather — find similar clusters
        log("Phase 2: Gather — clustering by similarity")
        clusters = find_clusters(memories, threshold=0.85)
        log(f"  Found {len(clusters)} clusters to consolidate")

        # Phase 3: Consolidate
        log("Phase 3: Consolidate — merging clusters via LLM")
        merged_count = 0
        for i, cluster in enumerate(clusters):
            log(f"  Cluster {i+1}/{len(clusters)}: {len(cluster)} memories")
            consolidated = consolidate_cluster(cluster)
            if not consolidated:
                log(f"    Skipped (LLM failed)")
                continue

            # Log what we're merging (for recovery)
            originals = [{"id": m.get("id", "?"), "summary": m.get("summary", "?")} for m in cluster]
            dream_log.append({
                "action": "merge",
                "originals": originals,
                "consolidated": consolidated,
            })

            # Delete originals, store consolidated
            for m in cluster:
                if m.get("id"):
                    delete_memory(m["id"])

            # Inherit the highest confidence from the cluster
            max_confidence = max(
                (m.get("extra", {}).get("confidence", 0.8) for m in cluster),
                default=0.8,
            )
            best_class = "knowledge"
            for m in cluster:
                mc = m.get("extra", {}).get("memory_class", "knowledge")
                if mc == "permanent":
                    best_class = "permanent"
                    break

            store_memory(consolidated, confidence=min(1.0, max_confidence + 0.05), memory_class=best_class)
            merged_count += 1
            log(f"    Merged into: {consolidated[:80]}...")

        # Phase 4: Prune — remove decayed memories
        log("Phase 4: Prune — removing low-confidence memories")
        now = datetime.now(timezone.utc)
        pruned_count = 0
        half_lives = {"permanent": None, "knowledge": 90.0, "context": 30.0, "progress": 7.0}
        for m in memories:
            extra = m.get("extra", {})
            confidence = extra.get("confidence", 0.8)
            memory_class = extra.get("memory_class", "knowledge")
            hl = half_lives.get(memory_class)
            if hl is None:
                continue  # permanent — never prune

            updated = m.get("updated_at", m.get("created_at"))
            if updated and isinstance(updated, str):
                try:
                    import pendulum
                    updated_dt = pendulum.parse(updated)
                    days_ago = (now - updated_dt).total_seconds() / 86400
                    effective_conf = confidence * math.exp(-0.693 * days_ago / hl)
                    if effective_conf < CONFIDENCE_PRUNE_THRESHOLD:
                        item_id = m.get("id")
                        if item_id:
                            dream_log.append({
                                "action": "prune",
                                "id": item_id,
                                "summary": m.get("summary", "?")[:100],
                                "effective_confidence": round(effective_conf, 3),
                            })
                            delete_memory(item_id)
                            pruned_count += 1
                except Exception:
                    pass

        log(f"  Pruned {pruned_count} low-confidence memories")

        # Update dream status
        STATUS_FILE.write_text(json.dumps({
            "last_dream": time.time(),
            "memorize_since": 0,
            "last_merged": merged_count,
            "last_pruned": pruned_count,
            "last_total": len(memories),
        }))

        # Write dream log
        log_path = LOG_DIR / f"dream-{datetime.now().strftime('%Y-%m-%d')}.json"
        log_path.write_text(json.dumps(dream_log, indent=2))
        log(f"Dream log written to {log_path}")

    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()

    log(f"autoDream complete: {merged_count} merged, {pruned_count} pruned from {len(memories)} total")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Create cron wrapper script**

Create `scripts/dream-cron.sh`:

```bash
#!/usr/bin/env bash
# autoDream cron wrapper — runs consolidation against the memU sidecar.
# Cron entry: 30 3 * * * /home/garrett/nanoclaw/scripts/dream-cron.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Load environment
if [ -f "$PROJECT_DIR/.env.memu" ]; then
    set -a
    source "$PROJECT_DIR/.env.memu"
    set +a
fi

# Override for host access (not inside Docker)
export MEMU_SIDECAR_URL="${MEMU_SIDECAR_URL:-http://localhost:8100}"
export OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://localhost:11434}"
export DREAM_LOG_DIR="$PROJECT_DIR/logs"
export DREAM_CHAT_MODEL="${DREAM_CHAT_MODEL:-qwen3:0.6b}"

mkdir -p "$PROJECT_DIR/logs"

exec python3 "$PROJECT_DIR/memu-framework/dream.py" \
    >> "$PROJECT_DIR/logs/dream.log" 2>&1
```

- [ ] **Step 4: Make scripts executable**

Run: `chmod +x ~/nanoclaw/memu-framework/dream.py ~/nanoclaw/scripts/dream-cron.sh`

- [ ] **Step 5: Install cron entry**

Run: `(crontab -l 2>/dev/null; echo "30 3 * * * /home/garrett/nanoclaw/scripts/dream-cron.sh") | crontab -`
Verify: `crontab -l | grep dream`
Expected: `30 3 * * * /home/garrett/nanoclaw/scripts/dream-cron.sh`

- [ ] **Step 6: Commit**

```bash
git add memu-framework/dream.py memu-framework/sidecar.py scripts/dream-cron.sh
git commit -m "feat: add autoDream memory consolidation with cron scheduling"
```

---

### Task 7: Rebuild and Push

- [ ] **Step 1: Build TypeScript**

Run: `cd ~/nanoclaw && npm run build`
Expected: Clean build, no errors.

- [ ] **Step 2: Rebuild container image**

Run: `cd ~/nanoclaw && ./container/build.sh`
Expected: Docker image builds successfully.

- [ ] **Step 3: Rebuild memU sidecar**

Run: `cd ~/nanoclaw && docker compose -f docker-compose.memu.yml build memu-sidecar`
Expected: Sidecar image rebuilds with new endpoints.

- [ ] **Step 4: Push to origin**

Run: `git push origin main`
Expected: All commits pushed to morrowgarrett/nanoclaw.

- [ ] **Step 5: Restart services**

Run: `systemctl --user restart nanoclaw && docker compose -f docker-compose.memu.yml up -d`
Expected: Services come back up cleanly.

- [ ] **Step 6: Smoke test**

Run:
```bash
# Test briefing endpoint
curl -s http://localhost:8100/briefing?limit=3 -H "X-API-Key: $MEMU_API_KEY" | python3 -m json.tool

# Test dream status
curl -s http://localhost:8100/dream-status -H "X-API-Key: $MEMU_API_KEY" | python3 -m json.tool

# Test confidence in memorize
curl -s -X POST http://localhost:8100/memorize \
  -H "X-API-Key: $MEMU_API_KEY" -H "Content-Type: application/json" \
  -d '{"content": "smoke test memory", "confidence": 0.9, "memory_class": "progress"}' | python3 -m json.tool
```
Expected: All three return valid JSON without errors.
