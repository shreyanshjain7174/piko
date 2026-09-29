# Memory architecture — a graph that fits in a pocket

The memory layer is what makes Piko a companion instead of a keyboard: it remembers what you
said, organizes it, and offers it back at the right moment — a line on Home, a suggestion in
the evening, context for the rewriter. This document is the contract for that layer.

Influenced by cognee's operation model (`remember` / `recall` / `improve` / `forget`, session
memory as a fast cache that syncs into the graph in the background) — but rebuilt for the
real constraints of a phone. cognee assumes Postgres/Kuzu, background daemons and idle
servers. iOS gives us none of those (CONSTRAINTS C10: no persistent background agent), so
every design decision below exists to keep the graph **correct while being touched rarely**.

## Non-negotiables

1. **Nothing leaves the device.** The memory graph never syncs, never uploads, never
   phones home. It isinspectable and deletable by its owner.
2. **Recall is interactive-grade.** The Home line and suggestion card render from a query
   that must return in single-digit milliseconds — no model in the recall path.
3. **Battery is a budget, not a vibe.** Work is tiered: the cheapest tier runs always,
   the expensive tier runs only when the system grants opportunistic time. Nothing polls.
4. **Memory is visible.** The user can see every entity Piko remembers and forget any of
   it in one swipe. A memory the user can't inspect is surveillance, not companionship.

## The one-substrate decision

SQLite (WAL mode) is the **only** storage engine: results, edits, entities, edges and
metadata live in one file on the app group container. No embedded graph database, no
separate vector store, no Redis-style cache. A graph DB process (Kuzu, etc.) would add
memory weight and a second crash domain for zero query benefit at our scale — a phone's
personal graph is thousands of edges, not millions; `JOIN` on indexed integer keys is the
graph database. If a vector tier is ever needed, it lands as an `embeddings` table with a
BLOB column and a brute-force top-k scan — correct and fast enough below ~50k rows, and
still one substrate.

## Data model (schema v2, additive to v1)

```
results, edits, results_fts        -- v1: the raw journal (append-only, replayable)

entities(id, name UNIQUE, kind, first_seen, last_seen, hit_count)
edges(id, src, dst, relation, weight, last_seen, UNIQUE(src,dst,relation))
memory_meta(key, value)            -- watermarks, schema version
episodes(id, day, summary)         -- rollups; tier-1 output, written rarely
```

`results` is the **event-sourced journal**: the only source of truth, replayable from
scratch. The graph (entities/edges) is a **derived projection** — if it is ever corrupt or
the extractor improves, `rebuildGraph()` re-derives it from the journal without data loss.
This is the escape hatch that makes schema evolution safe on a device you cannot debug.

## Tiered intelligence — "activate only necessary things"

| Tier | Tool | Cost | When it runs |
|---|---|---|---|
| 0 | `NLTagger` (NER + nouns) | ~ms, no model load | Immediately after each result, debounced 2 s |
| 1 | Foundation Models (Brain) | seconds, Apple Intelligence | `BGProcessingTask` while charging; summarises episodes |
| 2 | Cloud agents | — | Never for memory. (Explicit opt-in surface only, v2+) |

Tier 0 is the whole v1 extractor: on-device NER for people/places/orgs plus noun
frequency for themes. It needs no model, loads no weights, and its output is enough for
"you've mentioned Interstellar three times this week." Tier 1 exists so episode summaries
and relation extraction can arrive later **without changing the recall contract** — the
BGTask writes into the same tables the recall query reads.

## Operations (the cognee mapping, mobile-sized)

- **remember** = `record(result)` (journal append, already exists) + `indexNewResults()`
  (watermark-based incremental extraction). Idempotent by construction: the watermark is
  `max(results.rowid)` processed; re-running processes zero rows and duplicates nothing.
- **recall** = `recall(query:)` → `MemoryPacket`. Hybrid ranking in one SQL pass:
  entity hits (FTS match + entity overlap) × recency decay × frequency. No model call.
- **improve** = the existing `EditPair` loop (nearest corrections as few-shot examples).
- **forget** = `forget(entity:)` (one swipe in Memory UI) and `delete(result:)` (History),
  both cascading to edges. User-visible, immediate, no soft-delete limbo.

## When the graph is touched

- **On result** (foreground, debounced 2 s): tier-0 extraction in one transaction.
- **On charge** (`BGProcessingTask`, `requiresExternalPowerConnection`): tier-1 rollups,
  graph compaction (cap edges per node, prune `last_seen` older than 180 days).
- **Never on a timer.** No heartbeat, no background refresh, no polling of anything.
  C10 is respected by construction, not by discipline.

## Latency & footprint budgets

- `recall(query:)`: ≤ 5 ms warm (single prepared statement, WAL, 2 MB page cache cap
  `PRAGMA cache_size=-2000`).
- Tier-0 extraction: ≤ 10 ms per result, batched per debounce window.
- Graph size ceiling: compacted to O(entities + edges) with hard caps (top-64 edges per
  relation class; entities unseen for 180 days archived out of the hot graph).
- Process cost: zero new processes, zero new frameworks beyond `NaturalLanguage`
  (system, no weight download). The keyboard extension is untouched — memory lives in
  the container app only.

## UX surfaces (why the graph exists)

- **Home memory line** — "Last time you said '…'" (already live), now served by recall.
- **Suggestion card** — `SuggestionEngine` turns a `MemoryPacket` into at most one
  gentle, time-aware line ("You've mentioned Interstellar a few times — tonight might be
  the night."). Suggestions, never solutions; no exclamation marks; cooldown-gated so it
  can appear at most once per session-hour and never during capture/tidying.
- **Piko's voice** — the suggestion may be *spoken* softly (on-device
  `AVSpeechSynthesizer`, cute tuning: pitch 1.32, rate 0.46, volume 0.5). Opt-out in
  Settings; never speaks while the mic is live — the buddy doesn't talk over you.
- **"What Piko remembers"** — Settings screen listing entities with hit counts and
  last-seen, swipe-to-forget. The transparency contract made visible.

## Failure modes

- Extractor crash mid-batch → transaction rolls back, watermark unmoved, next attempt
  retries the same rows. No partial graph.
- Corrupt graph → drop graph tables, keep journal, rebuild from watermark 0.
- Recall timeout (can't happen by design, but) → callers already render `nil` packets
  as the honest fallback copy. Memory is never allowed to block the UI.
