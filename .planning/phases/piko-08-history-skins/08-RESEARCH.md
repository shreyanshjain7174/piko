# Phase 8: Local History & Skins - Research

**Researched:** 2026-08-30
**Domain:** Raw SQLite3 C API + FTS5 full-text search (via `import SQLite3`), local file storage placement, Swift actor concurrency, SwiftUI list/search UI, SwiftUI skin picker
**Confidence:** MEDIUM-HIGH (FTS5 C API surface HIGH, verified against sqlite.org; iOS-system-library FTS5 availability MEDIUM — flagged explicitly below, this is the one item that needs a runtime check, not an assumption; storage placement and actor design HIGH, derived directly from this project's own conventions and CONSTRAINTS.md)

## Summary

Phase 8 turns two complete stubs into real, persisted, working features: `SQLiteMemory`
(currently `init(path:) { /* TODO */ }` with every method a no-op) becomes a real SQLite3 +
FTS5-backed implementation matching `EphemeralMemory`'s behavior contract, and `PikoFace`/
`ArmView` gain a real skin picker and history list — the first time `PikoFace` renders anywhere
in the running app.

**Three findings shape the plan and must be decided/verified before or during planning, not
discovered mid-task:**

1. **FTS5 availability on Apple's system-bundled SQLite is a runtime fact, not a training-data
   fact, and this research could not verify it with an authoritative fetched source this
   session.** SQLite's own `fts5.html` docs say FTS5 has shipped in the amalgamation since
   3.9.0 (2015) but is compiled in only when `SQLITE_ENABLE_FTS5` is defined at build time — a
   decision Apple makes for its system library, not SQLite upstream. The only source found this
   session that mentions Apple's system SQLite build directly (GRDB's own docs, fetched
   verbatim) says the opposite of "just works": *"To use FTS5, you'll need a custom SQLite build
   that activates the `SQLITE_ENABLE_FTS5` compilation option"* and *"A custom SQLite build can
   activate extra SQLite features... such as support for the FTS5 full-text search engine"* —
   both statements imply Apple's system library historically did **not** enable FTS5 by default,
   which is why GRDB ships an entire alternate build pipeline for apps that need it. This
   documentation is not dated and may be stale relative to a recent iOS SDK; widely-repeated
   developer folklore (undated blog posts, forum answers, not independently fetched and verified
   this session) holds that Apple's system library has included FTS5 since iOS 11.4 (2018),
   which would make it a non-issue on this project's iOS 26 floor. **Both cannot be safely
   asserted as fact from this session's research alone.** Tag: `[ASSUMED]` — must be verified at
   plan/implementation time with a two-line runtime check (Pitfall 1, Common Pitfalls) before any
   `CREATE VIRTUAL TABLE ... USING fts5` statement is trusted.
2. **App-private storage is correct here, not the App Group.** Every other piece of persistent
   state in this codebase (`draft.json`, `result.json`, `state.json`) lives in the App Group
   container because the keyboard extension and widget extension both need to read it. History
   has no such requirement — `HIST-01`/`HIST-02`/`SKIN-01` only ever need to be written and read
   by the container app's own process (`CaptureCoordinator` writes, `ArmView`'s new history list
   reads). Defaulting to the App Group "because that's where state lives" would be copying a
   pattern past the point it applies. See finding 2 below for the concrete path.
3. **`web/index.html` has a real, complete, already-designed SVG character** — not a placeholder,
   not something to invent from scratch, and not a large illustration undertaking either. It is
   one `<svg>` string (~25 elements: paths, circles, ellipses, one rect) with skin/phase variants
   already implemented as CSS-class toggles (`.only-cute`, `.only-cool`, `.only-hero`,
   `.only-sparkle`, `.eyes-open`, `.eyes-wide`, `.eyes-happy`, `.m-idle`, `.m-open`, `.m-think`).
   Porting it is a bounded translation task (SVG path data → SwiftUI `Path`), not a multi-day
   illustration effort — see finding 7 below for the concrete size estimate.

**Primary recommendation:** Implement `SQLiteMemory` as a Swift `actor` wrapping a single
`OpaquePointer` (the `sqlite3*` handle) plus long-lived prepared `OpaquePointer` statements,
using the real `sqlite3_open_v2`/`sqlite3_prepare_v2`/`sqlite3_bind_text`/`sqlite3_step` C API
(verified against sqlite.org, not invented — see AGENTS.md's explicit warning about inventing API
signatures, which applies here exactly as it does to SpeechAnalyzer/ActivityKit). Store the
database file in the container app's own Application Support directory, not the App Group.
Wire `AppComposition` to construct it once and pass it to `CaptureCoordinator`, which calls
`memory.record(result)` immediately after the existing `channel.writeResult(result)` line — the
same "finalize once, fan out" pattern Phase 7 already established for `onTidyingChange`.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| SQLite file I/O, FTS5 indexing, actor-isolated access | Container App (`PikoMemory` SPM target) | — | `PikoMemory` already exists as a cross-platform SPM target (targets `.iOS(.v26)` and `.macOS(.v15)` per `Package.swift`); no platform-specific API is needed for raw `SQLite3`, so this stays a portable library target, not an `App/Piko`-only file |
| `Memory.record`/`search` call sites | Container App (`App/Piko/CaptureCoordinator.swift`, `App/Piko/AppComposition.swift`) | — | Only the container app produces `CaptureResult` (Phase 5/6) and only the container app's UI (`ArmView`) needs to read history back — no cross-process requirement exists per HIST-01/HIST-02/SKIN-01 |
| History list + search UI | Container App (`App/Piko/PikoApp.swift` `ArmView`, or a new pushed view) | — | v0.1 is a one-screen app per `docs/SPEC.md`; no `NavigationStack` exists yet — this phase is the first to need one |
| Skin picker UI + persistence | Container App (`App/Piko/PikoApp.swift` `ArmView`) writing through `SessionChannel.writeState` | Keyboard extension (reads `SessionState.skin`, unaffected) | `SessionState.skin` and the App-Group-backed `writeState`/`readState` mechanism already exist (Phase 1); the picker is a pure UI addition over existing plumbing, not new storage |
| `PikoFace` character rendering | `PikoUI` (already exists, currently unused by the app) | — | This phase is where `PikoFace` first appears in `App/Piko`, per the user's own framing — no new module needed |

## User Constraints (from ROADMAP.md / REQUIREMENTS.md — no CONTEXT.md exists yet for this phase)

### Locked Decisions
- **Requirements:** HIST-01 (every capture session recorded to local history), HIST-02 (local
  history is searchable), SKIN-01 (four skins available and selectable locally, no network call)
- **Success Criteria (ROADMAP.md):** (1) every completed capture session appears in local
  history; (2) history is searchable by content; (3) four skins exist and can be selected
  locally, with no network call involved
- **`docs/SPEC.md` PikoMemory contract:** "SQLite with FTS5. Retrieval, never a growing prompt —
  the on-device context window is 8,192 tokens and months of sessions will not fit in it, so do
  not try." Acceptance target stated there: "10,000 stored sessions still search in under 50 ms;
  the database survives an app kill mid-write."
- **`Skin` enum already has exactly 4 cases** (`cute, cool, hero, sparkle`) in
  `Sources/PikoKit/Contracts.swift` — SKIN-01 needs zero new cases, only a picker UI and
  persistence wiring
- **`AGENTS.md`/`CLAUDE.md`:** never invent an API signature from memory for anything
  fast-moving; the same discipline is extended here to SQLite3/FTS5 C API calls, per the user's
  explicit instruction — a wrong C API call can silently corrupt the on-device database, which
  this research treats as a **worse** failure mode than a compile error, exactly as instructed
- **No shortcuts, no stub:** "we need everything to be working as expected... not a stub or a
  shortcut (e.g. real SQLite FTS5, not a flat JSON array pretending to be a search index)" — this
  rules out any interim substring-scan-over-JSON approach as the *shipped* implementation
  (`EphemeralMemory` already exists and correctly serves that role for tests/previews only)

### Claude's Discretion
- Exact FTS5 table schema (external-content vs. plain FTS5 table — see finding/pattern below,
  recommendation given but not mandated)
- Whether history list UI is inline in `ArmView` or a separate pushed screen (both satisfy
  HIST-01/02; `docs/SPEC.md`'s "no settings screen with more than one screen of options"
  non-goal is about settings, not history, but the one-screen-app framing is still a real
  constraint to respect)
- `nearestEdits`/`recordEdit`/`lexicon` **implementation correctness** (protocol conformance
  requires real, working bodies matching `EphemeralMemory`'s behavior) vs. **new caller wiring**
  for those three (explicitly NOT required by HIST-01/HIST-02/SKIN-01 — see Don't Hand-Roll)

### Deferred Ideas (OUT OF SCOPE)
- Edit-pair learning loop wiring (`recordEdit` being called from anywhere in the app) — protocol
  conformance only, no new caller this phase
- Lexicon-driven transcription bias (`lexicon(limit:)` feeding `Transcriber.setLexicon`) — same
- Full SVG→SwiftUI port of `PikoFace` as a *mandatory* deliverable — a real reference exists (see
  finding 7) and porting it is a bounded task, but the exact scope (all 4 skins × all 4 phases in
  one pass, vs. structural shapes now + polish later) is a planning decision, not something this
  research should silently commit to

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| HIST-01 | Every completed capture session appears in local history | `CaptureCoordinator.stopCapture()` calls `memory.record(result)` right after the existing `channel.writeResult(result)` line (Pattern 3) |
| HIST-02 | Local history is searchable by content | `SQLiteMemory.search(_:limit:)` backed by a real `fts5` virtual table queried via `MATCH`, exposed to SwiftUI via `.searchable` (Pattern 5) |
| SKIN-01 | Four skins exist and are selectable locally, no network call | `Skin.allCases` (already `CaseIterable`) drives a picker that calls the existing `SessionChannel.writeState` (Pattern 6) — zero new storage mechanism |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|---------------|
| `SQLite3` (system C library, `import SQLite3`) | Bundled with iOS 26 SDK | Raw database engine + FTS5 virtual table module | Zero external dependency, matches `Package.swift`'s existing pattern of declaring **no** `dependencies:` array at all — this project has never added a package dependency and there is no signal anywhere in the repo (docs, `Package.swift`, `AGENTS.md`) that a wrapper library (GRDB, SQLite.swift) was ever considered or is wanted [VERIFIED: `Package.swift` has zero `dependencies:` entries, confirmed by reading the file directly] |
| Swift `actor` (language feature) | Swift 6.2 (project tools-version) | Single-writer/single-reader serialization around the raw `sqlite3*` handle | Matches this project's existing concurrency style exactly — `EphemeralMemory` in the same file is already `public actor EphemeralMemory: Memory`, so `SQLiteMemory` following the identical shape is not a new pattern, just a new implementation body [VERIFIED: read `Sources/PikoMemory/SQLiteMemory.swift` directly] |

### Supporting
| Piece | Purpose | When to Use |
|-------|---------|-------------|
| `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)` | Locate the app-private storage directory for the `.sqlite` file | At `SQLiteMemory` construction time in `AppComposition`, once, not per-call |
| `sqlite3_prepare_v2` (not the deprecated `sqlite3_prepare`) | Compile SQL into a reusable prepared statement | Every query and insert; recommended by sqlite.org over the legacy v1 API [CITED: sqlite.org/c3ref/prepare.html, fetched this session: "The sqlite3_prepare() interface is legacy and should be avoided... prepare_v2()... are recommended for all new programs"] |
| `sqlite3_bind_text(_:_:_:_:SQLITE_TRANSIENT)` | Safely bind arbitrary Swift `String` values (including quotes/special characters) into prepared statement parameters | Every `record`, `recordEdit`, `search` call — never string-interpolate a transcript into raw SQL |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Raw `SQLite3` C API | GRDB (SPM dependency) | GRDB gives ergonomic Swift wrappers (`FTS5Pattern`, query builder, migrations) and ships its **own bundled SQLite build with FTS5 pre-enabled**, sidestepping finding 1 entirely — but it is a new external dependency this project has never taken, `Package.swift` has zero `dependencies:` entries today, and adding one is a real architectural decision the user did not ask for. Flag as a legitimate alternative if the FTS5-availability verification (Pitfall 1) fails on-device; do not adopt silently |
| Raw `SQLite3` C API | SQLite.swift (SPM dependency) | Same tradeoff as GRDB, lighter-weight wrapper, less full-text tooling than GRDB (no built-in `FTS5Pattern` sanitization helper) — a real Swift production library confirms the `SQLITE_TRANSIENT`/`sqlite3_bind_text` pattern this research recommends [VERIFIED: read `stephencelis/SQLite.swift`'s `Statement.swift` and `Connection.swift` directly, both fetched this session] |
| App-private storage | App Group container (`AppGroup.identifier`) | Only needed if the keyboard or widget extension must read history directly — not required by any stated success criterion. Costs: widens the App Group container's contents for no benefit, and (per C4) the keyboard extension must never open a database at all, so putting the file in the App Group buys nothing even for that process |
| Plain FTS5 table (verbatim + FTS5 columns together) | External-content FTS5 table (`content=` pointing at a separate non-virtual table) | External-content saves disk space by not duplicating the raw text a second time inside the FTS index, at the cost of needing manual `INSERT`/`DELETE` triggers or app-code synchronization between the two tables [CITED: sqlite.org/fts5.html §4.4.3, fetched this session]. For a single-writer actor doing exactly one `INSERT` per `record()` call and no `UPDATE`/`DELETE` of history rows, the synchronization complexity is not justified by the (small, per-session-text) space savings — plain FTS5 table recommended |

**Installation:**
```swift
import SQLite3   // System SQLite3 module — no Package.swift changes needed
```

**Version verification:** No package manager entry to verify — `SQLite3` is a system module map
shipped in the iOS 26 / Xcode 26.3 SDK, confirmed as the correct import statement by direct
inspection of a real, widely-used production Swift SQLite wrapper's source
(`stephencelis/SQLite.swift`'s `Connection.swift`, which itself only does `import SQLite3` with
no external C dependency for the non-SQLCipher build) [VERIFIED, fetched this session].

## Package Legitimacy Audit

> No external packages recommended. `SQLite3` is a first-party system library already available
> via `import SQLite3` on every Apple platform target in this project; no `Package.swift` change
> is needed. `slopcheck`/registry verification does not apply to system frameworks.

| Package | Registry | Age | Downloads | Source Repo | slopcheck | Disposition |
|---------|----------|-----|-----------|-------------|-----------|-------------|
| SQLite3 | Apple (system) | Bundled since early iOS, FTS5-capability era disputed — see Pitfall 1 | N/A | Apple internal / upstream sqlite.org | N/A | Approved — first-party, zero new dependency |

**Packages removed due to slopcheck [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

## Architecture Patterns

### System Architecture Diagram

```
┌────────────────────────── Container App (App/Piko) ──────────────────────────┐
│                                                                                │
│  AppComposition (sole construction site)                                     │
│    ├── SessionCoordinator      (unchanged)                                   │
│    ├── CaptureCoordinator                                                    │
│    │     stopCapture():                                                      │
│    │       ... existing rewrite/timing logic ...                            │
│    │       channel.writeResult(result)     ← existing (Phase 5/6)            │
│    │       channel.post(.resultReady)      ← existing                       │
│    │       await memory.record(result)     ← NEW, same call site            │
│    ├── LiveActivityController  (unchanged, Phase 7)                          │
│    └── memory: any Memory = SQLiteMemory(path: appSupportURL)  ← NEW         │
│                                                                                │
│  ArmView (App/Piko/PikoApp.swift)                                            │
│    ├── PikoFace(phase:, skin:)              ← NEW, first real use in the app │
│    ├── Skin picker (Skin.allCases)          ← NEW                            │
│    │      writes SessionState via channel.writeState(...) (existing method)  │
│    └── History list, NavigationStack + .searchable                          │
│           reads via memory.search(query, limit:) / initial unfiltered load   │
│                                                                                │
└────────────────────────────────────────────────────────────────────────────────┘

Sources/PikoMemory/SQLiteMemory.swift (SPM target, iOS 26 + macOS 15):

  public actor SQLiteMemory: Memory {
      private var db: OpaquePointer?               // sqlite3* handle
      private var insertResultStmt: OpaquePointer?  // prepared, reused
      private var searchStmt: OpaquePointer?        // prepared, reused
      ...
      public init(path: URL) throws {
          sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
          try execute("""
              CREATE TABLE IF NOT EXISTS results (
                  id TEXT PRIMARY KEY, raw TEXT NOT NULL, shipped TEXT NOT NULL,
                  route TEXT NOT NULL, profile TEXT NOT NULL,
                  createdAt REAL NOT NULL,
                  firstWordMS INTEGER NOT NULL, transcribeMS INTEGER NOT NULL, brainMS INTEGER NOT NULL
              );
              """)
          try execute("""
              CREATE VIRTUAL TABLE IF NOT EXISTS results_fts USING fts5(
                  raw, shipped, content='results', content_rowid='rowid'
              );
              """)
          // triggers to keep results_fts in sync with results — see Pattern 2
      }
  }
```

### Recommended Project Structure
```
Sources/PikoMemory/
└── SQLiteMemory.swift    # existing file, stub body replaced — no new files needed
                           # (EphemeralMemory stays in the same file, unchanged)

App/Piko/
├── AppComposition.swift  # add `let memory: any Memory = SQLiteMemory(...)`, construct once
├── CaptureCoordinator.swift   # add one line: `await memory.record(result)`
└── PikoApp.swift         # ArmView: add NavigationStack, PikoFace, skin picker, history list
```

### Pattern 1: Real `sqlite3_open_v2` / `sqlite3_prepare_v2` / `sqlite3_step` Flow
**What:** The canonical open-prepare-bind-step-finalize lifecycle, verified against sqlite.org's
own C API reference rather than reconstructed from memory (per AGENTS.md's SpeechAnalyzer/
ActivityKit-style warning, extended here to SQLite3/FTS5).
**When to use:** Every read and write path in `SQLiteMemory`.
```swift
// Source: sqlite.org/c3ref/prepare.html, sqlite.org/c3ref/bind_blob.html (both fetched this
// session — signatures verbatim, not reconstructed from training data)
import SQLite3

// SQLITE_TRANSIENT / SQLITE_STATIC are C function-like macros that Swift's Clang importer does
// NOT expose as usable Swift symbols (they expand to casts, which don't survive import). This
// redefinition is the standard, widely-used workaround — confirmed present in a real production
// Swift SQLite wrapper's source this session (stephencelis/SQLite.swift uses the bare name
// `SQLITE_TRANSIENT` throughout `Statement.swift`, which is only possible because the library
// defines it once, exactly this way, elsewhere in its sources).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func insertResult(_ result: CaptureResult, into db: OpaquePointer?) throws {
    var stmt: OpaquePointer?
    let sql = "INSERT INTO results (id, raw, shipped, route, profile, createdAt, firstWordMS, transcribeMS, brainMS) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw SQLiteMemoryError.prepareFailed(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, result.id.uuidString, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(stmt, 2, result.raw, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(stmt, 3, result.shipped, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(stmt, 4, result.route.rawValue, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(stmt, 5, result.profile.rawValue, -1, SQLITE_TRANSIENT)
    sqlite3_bind_double(stmt, 6, result.createdAt.timeIntervalSince1970)
    sqlite3_bind_int(stmt, 7, Int32(result.timings.firstWordMS))
    sqlite3_bind_int(stmt, 8, Int32(result.timings.transcribeMS))
    sqlite3_bind_int(stmt, 9, Int32(result.timings.brainMS))

    guard sqlite3_step(stmt) == SQLITE_DONE else {
        throw SQLiteMemoryError.stepFailed(String(cString: sqlite3_errmsg(db)))
    }
}
```
Note the parameter index is 1-based (`sqlite3_bind_*`'s "leftmost SQL parameter has an index of
1" — [CITED: sqlite.org/c3ref/bind_blob.html, fetched this session]), and every `?` gets bound —
**never** string-interpolate `result.raw`/`result.shipped` into the SQL text, since transcript
text is arbitrary user speech that will contain quotes, apostrophes, and any other character.

### Pattern 2: FTS5 Virtual Table Kept in Sync via Triggers (External-Content Table)
**What:** A plain content table (`results`) holding all the real `CaptureResult` columns, plus an
`fts5` virtual table (`results_fts`) configured as an **external-content** table
(`content='results', content_rowid='rowid'`) indexing only the `raw`/`shipped` text columns.
Three `AFTER INSERT`/`AFTER UPDATE`/`AFTER DELETE` triggers on `results` keep `results_fts` in
sync automatically — this is SQLite's own documented pattern for this exact situation, not a
custom design.
**When to use:** Table creation, once, in `init(path:)`.
```sql
-- Source: sqlite.org/fts5.html §4.4.3 "External Content Tables", fetched this session
CREATE TABLE IF NOT EXISTS results (
    rowid INTEGER PRIMARY KEY,   -- the implicit rowid, made explicit so content_rowid can name it
    id TEXT NOT NULL UNIQUE,
    raw TEXT NOT NULL,
    shipped TEXT NOT NULL,
    route TEXT NOT NULL,
    profile TEXT NOT NULL,
    createdAt REAL NOT NULL,
    firstWordMS INTEGER NOT NULL,
    transcribeMS INTEGER NOT NULL,
    brainMS INTEGER NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS results_fts USING fts5(
    raw, shipped,
    content='results',
    content_rowid='rowid'
);

CREATE TRIGGER IF NOT EXISTS results_ai AFTER INSERT ON results BEGIN
    INSERT INTO results_fts(rowid, raw, shipped) VALUES (new.rowid, new.raw, new.shipped);
END;
-- HIST-01/HIST-02 never update or delete a history row in this phase's scope, so the
-- AFTER UPDATE / AFTER DELETE triggers are omitted for now — add them only if a future
-- phase introduces history editing or deletion (a real gap to flag, not silently build).
```
Whether to also add the update/delete triggers now (for forward-compatibility, e.g., a future
"delete this session from history" feature) or omit them until actually needed is a Claude's
Discretion item for the planner — SQLite's own docs warn that an external-content table with
incomplete trigger coverage silently drifts out of sync the moment an omitted operation occurs
[CITED: sqlite.org/fts5.html §4.4.4 "External Content Table Pitfalls"], so if `updateAll`/`delete`
is added later, the missing triggers must be added in the same change, not as an afterthought.

### Pattern 3: `search(_:limit:)` via `MATCH`, Joined Back to the Content Table
**What:** FTS5 `MATCH` queries only return `rowid` and the two indexed columns efficiently; to
reconstruct a full `CaptureResult` (with `route`, `profile`, `timings`, etc.) the query must join
`results_fts` back to `results` by `rowid`.
```sql
-- Source: sqlite.org/fts5.html §1 "Overview of FTS5" (MATCH examples), adapted for the join
-- this project's join-back need requires (external-content tables cannot themselves return the
-- non-indexed columns like `profile`/`createdAt`/`timings`)
SELECT r.id, r.raw, r.shipped, r.route, r.profile, r.createdAt, r.firstWordMS, r.transcribeMS, r.brainMS
FROM results_fts f
JOIN results r ON r.rowid = f.rowid
WHERE results_fts MATCH ?
ORDER BY rank
LIMIT ?;
```
```swift
public func search(_ query: String, limit: Int) async -> [CaptureResult] {
    guard !query.isEmpty else { return [] }
    // See Pitfall 2: sanitize the raw user query into a safe FTS5 MATCH expression before binding.
    let ftsQuery = Self.sanitizedMatchExpression(for: query)
    var stmt: OpaquePointer?
    let sql = """
        SELECT r.id, r.raw, r.shipped, r.route, r.profile, r.createdAt,
               r.firstWordMS, r.transcribeMS, r.brainMS
        FROM results_fts f JOIN results r ON r.rowid = f.rowid
        WHERE results_fts MATCH ? ORDER BY rank LIMIT ?
        """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, ftsQuery, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int(stmt, 2, Int32(limit))

    var results: [CaptureResult] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        results.append(decodeCaptureResult(from: stmt))
    }
    return results
}
```
`ORDER BY rank` sorts best-matches-first using FTS5's built-in `bm25()`-backed `rank` column
[CITED: sqlite.org/fts5.html §5.2 "Sorting by Auxiliary Function Results" — "using rank is faster
than using bm25() [directly]"], matching `EphemeralMemory`'s `suffix(limit).reversed()`
recency-ish behavior closely enough to be a reasonable, real ranking rather than an arbitrary one.

### Pattern 4: Wiring `CaptureCoordinator.stopCapture()` to Record History
**What:** One new line, placed at the exact point the phase description specifies — right after
the existing `channel.writeResult(result)`/`channel.post(.resultReady)` pair, matching the
established "finalize once, fan out to every interested consumer" shape `onTidyingChange` already
uses in the same function.
```swift
// App/Piko/CaptureCoordinator.swift — stopCapture(), existing code shown for context
channel.writeResult(result)
channel.post(.resultReady)
await memory.record(result)     // NEW — the only line HIST-01 needs in this function
onTidyingChange?(false)
```
`CaptureCoordinator`'s initializer needs one new parameter (`memory: any Memory`), matching the
existing `session`/`channel`/`transcriber`/`brain` parameter shape exactly — no new construction
pattern, just one more protocol-typed dependency threaded through the same init.

### Pattern 5: `AppComposition` Construction Site — App-Private Path
**What:** Construct `SQLiteMemory` once, at the same place every other real (non-mock) dependency
is constructed, using `FileManager`'s dedicated Application Support API rather than a hand-rolled
path.
```swift
// App/Piko/AppComposition.swift, inside `private init()`
let appSupportURL = try! FileManager.default.url(
    for: .applicationSupportDirectory, in: .userDomainMask,
    appropriateFor: nil, create: true)
let dbURL = appSupportURL.appendingPathComponent("history.sqlite")
let memory: any Memory
#if targetEnvironment(simulator)
memory = EphemeralMemory()   // matches the existing transcriber/brain simulator-mock pattern
#else
memory = try! SQLiteMemory(path: dbURL)
#endif
```
Whether to gate `SQLiteMemory` behind `#if targetEnvironment(simulator)` (matching the existing
`MockTranscriber`/`MockBrain` pattern) or use the real SQLite path on Simulator too (it is fully
testable there — see Test Strategy) is a real decision for the planner: SQLite has zero
hardware/entitlement dependency unlike Speech/ActivityKit, so `EphemeralMemory` on Simulator would
be gating something that doesn't need gating. **Recommendation: do not gate it** — use
`SQLiteMemory` on both Simulator and device, and reserve the `#if targetEnvironment(simulator)`
pattern for genuinely hardware-gated dependencies only, as it already is for transcriber/brain.

### Pattern 6: Skin Picker Reuses the Existing `SessionState`/`writeState` Mechanism
**What:** Exactly what `docs/SPEC.md`'s existing `existing?.skin ?? .cute` read pattern implies —
the picker constructs a new `SessionState` with every field carried over except `skin`, and calls
the same `SessionChannel.writeState` the app already uses for phase/heartbeat updates.
```swift
// ArmView, new skin picker — reuses AppComposition.shared.channel, no new storage
Picker("Skin", selection: $selectedSkin) {
    ForEach(Skin.allCases, id: \.self) { skin in
        Text(skin.rawValue.capitalized).tag(skin)
    }
}
.onChange(of: selectedSkin) { _, newSkin in
    let channel = AppComposition.shared.channel
    var state = channel.readState() ?? SessionState()
    state.skin = newSkin
    channel.writeState(state)
}
```
This is the same read-modify-write shape `SessionCoordinator` itself already uses internally
(per the phase description's note about `existing?.skin ?? .cute` in `SessionCoordinator`) — no
new persistence mechanism, no new file, no App Group change.

### Anti-Patterns to Avoid
- **String-interpolating transcript text into raw SQL:** `"INSERT INTO results VALUES ('\(raw)', ...)"`
  is exactly the SQL injection shape SQLite's own documentation warns about (with the "Little
  Bobby Tables" example cited directly in GRDB's docs) — even though this is 100% local,
  single-user data, a transcript containing an apostrophe (`"I'm running late"`) would silently
  corrupt or fail the insert with naive interpolation. Always use `sqlite3_bind_text` with `?`
  placeholders.
- **Binding a raw, unsanitized user search string straight to `MATCH`:** FTS5's query syntax
  treats `"`, `:`, `*`, `NOT`, `AND`, `OR`, and unbalanced parentheses as *syntax*, not literal
  characters — see Pitfall 2.
- **Recreating `EphemeralMemory`'s substring-scan approach "just to ship something":** explicitly
  ruled out by the user's own instruction (the flat-JSON/no-real-index example is named
  verbatim). `EphemeralMemory` stays exactly as-is for tests/previews; it is not a fallback
  implementation to promote into production use.
- **Gating `SQLiteMemory` behind a Simulator mock the way `SpeechTranscriberEngine`/`SystemBrain`
  are gated:** SQLite has no hardware dependency; doing so would introduce an unverified-on-device
  gap where none needs to exist (see Test Strategy — this is meant to be the first *fully*
  closeable phase, unlike Phases 3/7).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Full-text search / relevance ranking | A custom word-frequency scorer, or a naive `LIKE '%word%'` scan | FTS5's built-in `MATCH` + `rank` (bm25) | This is exactly the problem FTS5 exists to solve; a hand-rolled scanner would also not meet the stated "10,000 stored sessions still search in under 50 ms" acceptance target from `docs/SPEC.md` |
| SQL parameter safety | Manual string escaping / `.replacingOccurrences(of: "'", with: "''")` | `sqlite3_bind_text`/`sqlite3_bind_int`/etc. with `?` placeholders | Manual escaping is a well-known incomplete defense (doesn't handle every SQLite quoting edge case); the C API's binding mechanism handles all of them correctly by construction |
| FTS5 query-string sanitization | A regex stripping "special" characters from user search input | A small allow-list tokenizer that quotes each word and joins with `AND` (Pitfall 2) | Regex stripping is easy to get subtly wrong (misses `NEAR`, column-filter `:` syntax, etc.); an explicit "treat every space-separated chunk as a quoted literal" approach sidesteps the entire FTS5 grammar rather than trying to filter it |
| Cross-process history sync | Writing history through the App Group the way `draft`/`result`/`state` are shared | Nothing — no cross-process consumer exists for history (see finding 2) | Building this would be solving a problem HIST-01/HIST-02/SKIN-01 do not have |

**Key insight:** Every mechanism this phase needs except the FTS5 schema/queries themselves
already exists in the codebase in some form — `EphemeralMemory` already defines the exact
`Memory` protocol surface to match behaviorally, `SessionChannel.writeState` already handles the
skin persistence, and `CaptureCoordinator`'s existing "finalize once, fan out" shape already has
the right call site for `record()`. This phase is real new implementation work (the SQLite/FTS5
internals) wired into an otherwise-established shape.

## Common Pitfalls

### Pitfall 1: FTS5 May Not Be Compiled Into Apple's System SQLite (Verify, Don't Assume)
**What goes wrong:** `CREATE VIRTUAL TABLE ... USING fts5(...)` fails at runtime with a
`SQLITE_ERROR`/"no such module: fts5" if the system SQLite library was built without
`SQLITE_ENABLE_FTS5`.
**Why it happens:** This is a build-time flag Apple sets for its own SQLite build, not a
guarantee upstream SQLite provides — see the Summary's finding 1 for the conflicting evidence
found this session (GRDB's docs imply a custom build is needed; separate, unverified developer
folklore says Apple has shipped FTS5 since iOS 11.4). Neither could be confirmed against an
Apple-authored source this session.
**How to avoid:** Add a one-time runtime capability check before relying on FTS5, and fail loudly
(not silently) if it is missing:
```swift
// Verify FTS5 is actually present before trusting any CREATE VIRTUAL TABLE ... USING fts5 call.
// Source: sqlite.org "compile_options pragma" (sqlite.org/compile.html §1) documents
// PRAGMA compile_options as the supported way to introspect compile-time flags at runtime.
var stmt: OpaquePointer?
sqlite3_prepare_v2(db, "PRAGMA compile_options", -1, &stmt, nil)
var hasFTS5 = false
while sqlite3_step(stmt) == SQLITE_ROW {
    if let opt = sqlite3_column_text(stmt, 0), String(cString: opt) == "ENABLE_FTS5" {
        hasFTS5 = true
    }
}
sqlite3_finalize(stmt)
```
If this check fails on a real device/Simulator run (the very first thing to try once this phase
starts implementation), the two real fallbacks are: (a) adopt GRDB with its own bundled SQLite
(a genuine new-dependency decision, not a silent workaround), or (b) fall back to a
`LIKE '%token%'`-based search over the plain `results` table (meets HIST-02's "searchable"
requirement in a strictly weaker form, and would not meet `docs/SPEC.md`'s 50ms/10k-row target at
scale, but is a real, honest interim if FTS5 truly is unavailable). **Do not guess which of these
applies — run the check.**
**Warning signs:** `sqlite3_prepare_v2` returning non-`SQLITE_OK` specifically for the
`CREATE VIRTUAL TABLE ... USING fts5` statement, with an error message containing "no such
module."

### Pitfall 2: Raw User Search Text Bound Directly to `MATCH` Is Parsed as FTS5 Query Syntax, Not a Literal
**What goes wrong:** FTS5's `MATCH` right-hand side is not a plain string match target — it is a
small query language with its own operators (`AND`, `OR`, `NOT`, `NEAR(...)`, `*` for prefix,
`:` for column filters, `"..."` for phrases). A user typing something containing any of these
(e.g. searching for the literal word `"NOT"`, or a transcript fragment containing a colon like
`"call John: urgent"`) can produce a syntax error (`SQLITE_ERROR`) instead of a search result, or
worse, match differently than the user intended.
**Why it happens:** `sqlite3_bind_text` safely prevents *SQL* injection (the value can't
break out of being "the third argument to MATCH"), but it does nothing to prevent the bound
*text* from being parsed as FTS5 query syntax once SQLite hands it to the FTS5 module — these are
two different grammars at two different layers.
**How to avoid:** Build a sanitized match expression before binding — the simplest correct
approach for "search by content" (HIST-02 does not ask for boolean/phrase search operators) is to
tokenize the user's input on whitespace, wrap each token in double quotes (which FTS5 treats as a
literal string even if the token itself is a reserved word like `AND`), and join with an explicit
`AND`:
```swift
static func sanitizedMatchExpression(for query: String) -> String {
    let tokens = query.split(separator: " ").map { token -> String in
        "\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return tokens.joined(separator: " AND ")
}
```
This mirrors the *intent* of GRDB's `FTS5Pattern(matchingAllTokensIn:)` helper (confirmed to exist
for exactly this reason in GRDB's own docs, fetched this session) without adopting GRDB itself.
**Warning signs:** `search()` throwing/returning empty for queries containing colons, asterisks,
or the literal words "and"/"or"/"not"; `EphemeralMemory`'s equivalent
`localizedCaseInsensitiveContains` never had this problem since it does plain substring matching
— so this class of bug will not show up in `EphemeralMemory`-backed tests, only in real
`SQLiteMemory` + FTS5, another reason to add FTS5-specific tests, not just reuse
`EphemeralMemory`'s test suite unchanged.

### Pitfall 3: `SQLITE_TRANSIENT`/`SQLITE_STATIC` Are Not Directly Importable From C
**What goes wrong:** Writing `sqlite3_bind_text(stmt, 1, value, -1, SQLITE_TRANSIENT)` without
first defining `SQLITE_TRANSIENT` in Swift fails to compile — `SQLITE_TRANSIENT`/`SQLITE_STATIC`
are C preprocessor macros (`(sqlite3_destructor_type)-1` / `(sqlite3_destructor_type)0`) that
Swift's Clang importer does not translate into usable Swift symbols.
**Why it happens:** Swift's C-interop only imports symbols the preprocessor macro expands to a
value the importer can represent; a cast expression like this one is not one of those cases.
**How to avoid:** Define it once, at file or module scope: `private let SQLITE_TRANSIENT =
unsafeBitCast(-1, to: sqlite3_destructor_type.self)`. Confirmed as the real pattern used in
`stephencelis/SQLite.swift` (a genuine, widely-used production library, not a toy example)
this session — its `Statement.swift` calls `sqlite3_bind_text(handle, Int32(idx), value, -1,
SQLITE_TRANSIENT)` using the bare name, which only compiles because the constant is defined
exactly this way elsewhere in the library.
**Warning signs:** "Cannot find 'SQLITE_TRANSIENT' in scope" at the first `sqlite3_bind_text`
call site.

### Pitfall 4: `PikoMemory`'s `Package.swift` Target Has No Test Target Yet
**What goes wrong:** `Package.swift` today has `PikoKitTests` (which already depends on
`PikoMemory` — verified by reading `Package.swift` directly), but no dedicated `PikoMemoryTests`
target. Writing SQLite persistence/FTS5 tests without deciding where they live risks either
silently growing `PikoKitTests` past its stated scope or needing a `Package.swift` edit this
research flags but does not resolve.
**Why it happens:** `PikoMemory` was scaffolded (Phase 1-era) before any real implementation
existed to test.
**How to avoid:** This is a real, small planning decision: either (a) add tests to
`PikoKitTests` since it already has the dependency wired, matching the path of least
`Package.swift` change, or (b) add a new `PikoMemoryTests` target matching the
one-test-target-per-source-target convention every other module in this project follows
(`PikoBridgeTests`, `PikoAudioTests`, `PikoBrainTests`, etc.). Recommendation: **(b)**, for
consistency with the established convention, even though it is one more `Package.swift` edit.
**Warning signs:** N/A — this is a planning-time decision, not a runtime failure.

## Runtime State Inventory

> Not applicable — this phase adds new functionality (a new persistence layer, new UI) rather
> than renaming, rebranding, or migrating existing identifiers/state. No grep-invisible runtime
> state (stored data under an old name, live service config, OS-registered state, secrets, or
> stale build artifacts) is at risk here. Confirmed by reading `SQLiteMemory.swift` (currently a
> complete no-op stub with zero persisted state to migrate) and `AppComposition.swift` (no
> existing `Memory` construction to replace).

## Code Examples

### Verified FTS5 Table Creation (from sqlite.org, not reconstructed)
```sql
-- Source: sqlite.org/fts5.html §1 "Overview of FTS5", fetched this session, verbatim syntax
CREATE VIRTUAL TABLE email USING fts5(sender, title, body);
```

### Verified FTS5 MATCH Query Forms (all three equivalent)
```sql
-- Source: sqlite.org/fts5.html §1, fetched this session
SELECT * FROM email WHERE email MATCH 'fts5';
SELECT * FROM email WHERE email = 'fts5';
SELECT * FROM email('fts5');
```

### Verified `sqlite3_prepare_v2` Signature
```c
/* Source: sqlite.org/c3ref/prepare.html, fetched this session */
int sqlite3_prepare_v2(
  sqlite3 *db,
  const char *zSql,
  int nByte,
  sqlite3_stmt **ppStmt,
  const char **pzTail
);
```

### Verified `sqlite3_bind_text` Signature and Destructor Semantics
```c
/* Source: sqlite.org/c3ref/bind_blob.html, fetched this session */
int sqlite3_bind_text(sqlite3_stmt*, int, const char*, int, void(*)(void*));
/* "SQLITE_STATIC... the application remains responsible for disposing of the object."
   "SQLITE_TRANSIENT... the object is to be copied prior to the return from sqlite3_bind_*()...
   SQLite will then manage the lifetime of its private copy." — SQLITE_TRANSIENT is correct here
   since Swift String buffers are not guaranteed to outlive the bind call. */
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|---------------|--------|
| FTS3/FTS4 | FTS5 | FTS5 shipped in the SQLite amalgamation as of 3.9.0 (2015-10-14) [CITED: sqlite.org/fts5.html §2.1] | FTS5 has better incremental-load behavior on large doclists, native `rank`/bm25 support, and is the version `docs/SPEC.md` already names — no reason to consider FTS3/4 for new code |
| `sqlite3_prepare` (v1) | `sqlite3_prepare_v2`/`v3` | v2 has been the recommended interface for a long time; v1 is explicitly called "legacy" in current docs [CITED: sqlite.org/c3ref/prepare.html] | Use v2 (v3 only needed for the extra `prepFlags` argument, not needed here) |

**Deprecated/outdated:**
- `sqlite3_prepare` (v1): superseded by `sqlite3_prepare_v2`, which gives per-statement detailed
  error codes instead of a generic `SQLITE_ERROR` requiring a follow-up `sqlite3_reset()` call to
  diagnose [CITED: sqlite.org/c3ref/prepare.html]

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Apple's system-bundled SQLite on iOS 26 has FTS5 compiled in (`SQLITE_ENABLE_FTS5`) | Summary finding 1, Pitfall 1 | If wrong, every `CREATE VIRTUAL TABLE ... USING fts5` statement fails at runtime with "no such module: fts5" — the phase's core HIST-02 requirement cannot ship as designed without either (a) adopting GRDB's custom-build SQLite, or (b) falling back to a `LIKE`-based search that does not meet the 50ms/10k-row acceptance target in `docs/SPEC.md`. Mitigated by the mandatory runtime `PRAGMA compile_options` check in Pitfall 1, which must run before planning locks in the FTS5-based schema as final |
| A2 | App-private Application Support storage (not the App Group) is sufficient for HIST-01/HIST-02/SKIN-01 | Summary finding 2, Standard Stack "Alternatives Considered" | Low risk — no stated requirement contradicts this, and it is directly supported by "only the container app reads/writes history" being explicitly true today. Would only be wrong if a future phase needs the widget/keyboard to read history, which is out of scope here per REQUIREMENTS.md |
| A3 | `stephencelis/SQLite.swift`'s use of `SQLITE_TRANSIENT`/raw `import SQLite3` is representative of how the real, unwrapped `SQLite3` module behaves on this project's iOS 26 SDK | Pattern 1, Pitfall 3 | Low risk — this is a widely-used, actively maintained production library (confirmed via direct source read this session) exercising the exact same system module this project will use; the C ABI these calls rely on has been stable for many SQLite/iOS releases |

## Open Questions

1. **Is Apple's system SQLite build on this project's target iOS 26 SDK actually compiled with
   `SQLITE_ENABLE_FTS5`?**
   - What we know: FTS5 has been part of upstream SQLite since 2015; GRDB's own docs (fetched
     this session) discuss "custom SQLite builds" as the way to get FTS5, implying the *default*
     (system) build may not have it — but that documentation could be legacy/stale relative to
     current iOS.
   - What's unclear: No Apple-authored source was found or fetched this session that states
     Apple's current position either way.
   - Recommendation: Run the `PRAGMA compile_options` check (Pitfall 1) as the very first
     implementation step of this phase, on both Simulator and (per `CLAUDE.md`'s "a Simulator
     result is not a device result" house rule) a physical device, before writing a single line
     of schema-dependent code. This is a fast, cheap, fully-conclusive check — there is no reason
     to proceed on an assumption when a two-line runtime probe resolves it completely.

2. **Should the update/delete FTS5 sync triggers be built now, even though no feature in this
   phase deletes or edits a history row?**
   - What we know: `docs/SPEC.md` and REQUIREMENTS.md describe HIST-01/HIST-02 as write-once,
     read/search-many — no delete or edit operation is named anywhere.
   - What's unclear: Whether a near-future phase (not in this milestone) will want "delete this
     session" — if so, adding the trigger later requires care per SQLite's own external-content
     table pitfalls documentation.
   - Recommendation: Build only the `AFTER INSERT` trigger now (Pattern 2); note in code that
     `AFTER UPDATE`/`AFTER DELETE` triggers must be added together, not incrementally, if history
     mutation ever ships.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| SQLite3 (system) | `SQLiteMemory` | ✓ (assumed present on all Apple platforms; FTS5 sub-capability unverified — see A1) | Bundled with iOS 26 SDK | If FTS5 specifically is missing: LIKE-based search (weaker, see Pitfall 1) or adopt GRDB |
| Xcode / SPM build tooling | Building `PikoMemory` target | ✓ | Already used throughout this project | — |

**Missing dependencies with no fallback:** none identified.

**Missing dependencies with fallback:** FTS5 sub-capability of system SQLite (see A1/Pitfall 1) —
fallback path exists (LIKE-based search, or GRDB adoption) but should not be needed on iOS 26.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Swift Testing (`@Test`), per `CLAUDE.md`: "Swift Testing (`@Test`) for new tests, not XCTest" |
| Config file | none — SPM test targets use `Package.swift`'s `.testTarget(...)` declarations |
| Quick run command | `swift test --filter PikoMemoryTests` (or `PikoKitTests`, pending Pitfall 4's resolution) |
| Full suite command | `make test` (per `CLAUDE.md`: "`make test` runs SPM module tests — no simulator needed") |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|---------------------|--------------|
| HIST-01 | `record(_:)` persists a `CaptureResult`; a fresh `SQLiteMemory(path:)` instance opened against the same file sees it | unit | `swift test --filter testRecordPersistsAcrossReopen` | ❌ Wave 0 |
| HIST-01 | App-kill-mid-write does not corrupt the database (per `docs/SPEC.md`'s acceptance line) | unit (simulate via closing/reopening a fresh handle mid-sequence, not an actual process kill) | `swift test --filter testDatabaseSurvivesReopen` | ❌ Wave 0 |
| HIST-02 | `search(_:limit:)` finds a recorded result by a word from its `shipped` text | unit | `swift test --filter testSearchFindsWordInShippedText` | ❌ Wave 0 |
| HIST-02 | Multi-word queries, partial/prefix matches (per FTS5 semantics), and empty-result queries all behave correctly | unit | `swift test --filter testSearchMultiWordAndEmptyResults` | ❌ Wave 0 |
| HIST-02 | A query containing FTS5-reserved syntax characters (`:`, `*`, `AND`/`OR`/`NOT` as literal words) does not crash or misbehave (Pitfall 2) | unit | `swift test --filter testSearchSanitizesReservedSyntax` | ❌ Wave 0 |
| SKIN-01 | `Skin.allCases` has exactly 4 cases (already true — regression guard) | unit | `swift test --filter testSkinHasFourCases` | ✅ — trivially coverable in existing `PikoKitTests` |
| SKIN-01 | Selecting a skin writes a `SessionState` with the new skin via `SessionChannel.writeState` | unit (using the existing `MockSessionChannel` test double, per `Tests/PikoKeyboardTests/MockSessionChannel.swift`) | `swift test --filter testSkinPickerWritesState` | ❌ Wave 0 |
| (actor safety) | Concurrent `record`/`search` calls never crash or corrupt state (actor isolation should make this trivially true, but worth a real concurrent-stress test) | unit | `swift test --filter testConcurrentRecordAndSearch` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `swift test --filter PikoMemoryTests` (or the resolved target name)
- **Per wave merge:** `make test`
- **Phase gate:** Full suite green before `/gsd:verify-work` — **and, unlike Phases 3/7, this
  phase has no device-only verification gap.** SQLite persistence, FTS5 search correctness, and
  actor concurrency are all fully provable on macOS/Simulator with no hardware, entitlement, or
  ActivityKit/SpeechAnalyzer-style dependency. This is explicitly flagged as a difference from
  the prior two phases: **Phase 8 should be fully closeable without a "device-unverified" caveat
  in REQUIREMENTS.md's traceability table**, assuming Pitfall 1's FTS5-availability check passes.

### Wave 0 Gaps
- [ ] Resolve Pitfall 4 (test target placement: `PikoKitTests` vs. new `PikoMemoryTests`)
- [ ] `Tests/PikoMemoryTests/SQLiteMemoryTests.swift` (or the equivalent path in `PikoKitTests`) —
      covers HIST-01, HIST-02
- [ ] A `MockSessionChannel`-based test for the skin picker's `writeState` call — covers SKIN-01
- [ ] Run the `PRAGMA compile_options` FTS5 check (Pitfall 1) as a one-time manual verification,
      not necessarily a permanent automated test, before committing to the FTS5 schema

## Security Domain

> `security_enforcement` not found set to `false` in `.planning/config.json` at research time —
> treated as enabled per the skill's default.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-------------------|
| V2 Authentication | No | No auth surface in this phase — local, single-user data |
| V3 Session Management | No | Not applicable to local SQLite storage |
| V4 Access Control | No | Single-user, single-app-sandbox data; no access control model needed |
| V5 Input Validation | Yes | Parameterized `sqlite3_bind_*` calls for all SQL (Pattern 1); FTS5 `MATCH` query sanitization for user search input (Pitfall 2) |
| V6 Cryptography | No | No encryption requirement stated anywhere for local history (iOS's default file-system Data Protection applies automatically to app-private storage; no additional app-level crypto is in scope) |

### Known Threat Patterns for This Phase's Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|-----------------------|
| SQL injection via transcript text or search query containing quotes/special characters | Tampering | Parameterized queries via `sqlite3_bind_text`/`sqlite3_bind_int` — never string-interpolate into raw SQL (Pattern 1, Anti-Patterns) |
| FTS5 query-syntax injection (a search string parsed as `AND`/`NOT`/`NEAR(...)`/column-filter syntax instead of literal text) | Tampering (of search semantics, not data) | Sanitize/quote user search input before binding to `MATCH` (Pitfall 2) — this is specific to FTS5 and not covered by ordinary SQL parameter binding |
| Database file left world-readable if placed somewhere outside the app sandbox | Information Disclosure | App-private Application Support directory is inside the app's sandbox by construction; this phase's "app-private, not App Group" recommendation (finding 2) is itself the mitigation — do not widen the storage location without a stated reason |

## Sources

### Primary (HIGH confidence)
- sqlite.org/fts5.html — FTS5 overview, table creation options, external-content tables,
  MATCH/query syntax, `rank`/bm25 sorting (fetched this session, extensive verbatim quotes above)
- sqlite.org/c3ref/prepare.html — `sqlite3_prepare_v2` signature and v1-vs-v2 guidance (fetched
  this session)
- sqlite.org/c3ref/bind_blob.html — `sqlite3_bind_text`/`sqlite3_bind_blob` signatures,
  `SQLITE_STATIC`/`SQLITE_TRANSIENT` semantics (fetched this session)
- sqlite.org/compile.html — `SQLITE_THREADSAFE` compile-time modes, `PRAGMA compile_options`
  introspection mechanism (fetched this session)
- sqlite.org/threadsafe.html — Serialized/Multi-thread/Single-thread modes, default is
  "serialized" unless overridden (fetched this session)
- `stephencelis/SQLite.swift` (`Statement.swift`, `Connection.swift`) — real, production,
  widely-used Swift SQLite wrapper confirming `import SQLite3`, `SQLITE_TRANSIENT` usage pattern,
  and `sqlite3_bind_text`/`sqlite3_prepare`-family call shapes (fetched this session, source read
  directly, not summarized from a tutorial)
- This repository's own source: `Sources/PikoKit/Protocols.swift`, `Sources/PikoKit/Contracts.swift`,
  `Sources/PikoMemory/SQLiteMemory.swift`, `App/Piko/AppComposition.swift`,
  `App/Piko/CaptureCoordinator.swift`, `App/Piko/PikoApp.swift`, `Sources/PikoUI/PikoFace.swift`,
  `Sources/PikoBridge/DarwinChannel.swift`, `Package.swift`, `docs/SPEC.md`, `docs/ARCHITECTURE.md`,
  `docs/CONSTRAINTS.md`, `docs/TOOLING.md`, `CLAUDE.md`, `AGENTS.md`, `web/index.html`,
  `.planning/ROADMAP.md`, `.planning/REQUIREMENTS.md` — all read directly this session

### Secondary (MEDIUM confidence)
- GRDB (`groue/GRDB.swift`) documentation: `README.md`, `Documentation/FullTextSearch.md`,
  `Documentation/CustomSQLiteBuilds.md` — fetched this session; used for the FTS5-availability
  ambiguity (finding 1/A1), the external-content-table pattern (cross-checked against sqlite.org
  directly, not taken on GRDB's authority alone), and as a named alternative-library option. GRDB
  is a real, extremely widely-used library, but its statements about Apple's *system* SQLite
  build are the one claim in this research that could not be cross-verified against an
  Apple-authored source

### Tertiary (LOW confidence)
- None used as load-bearing claims — the one place a tertiary/undated-blog-post-style claim
  would normally appear (whether Apple's system SQLite includes FTS5) is instead flagged
  explicitly as unverified (A1) rather than stated as fact from an unverifiable source

## Metadata

**Confidence breakdown:**
- FTS5 C API surface (schema, MATCH, triggers, bind functions): HIGH — every code example above
  traces to a direct sqlite.org fetch this session, not reconstructed from training data
- FTS5 *availability* on Apple's system SQLite: MEDIUM, explicitly flagged as unverified (A1) —
  this is the one fact this research could not pin down with an authoritative source, and it is
  surfaced prominently rather than glossed over, per the user's explicit "verify, don't invent"
  instruction
- Storage location (app-private vs. App Group): HIGH — derived directly from this project's own
  stated requirements and existing App Group usage patterns, no external source needed
- Actor concurrency design: HIGH — matches this project's own existing `EphemeralMemory` actor
  shape exactly
- Character art assessment (`web/index.html`): HIGH — read the actual SVG source directly, no
  external claim involved

**Research date:** 2026-08-30
**Valid until:** 30 days for the FTS5 C API surface (stable, unlikely to change); the FTS5
availability question (A1) should be considered "unresolved" until the Pitfall 1 runtime check
is actually run — that check, not a calendar date, is what retires this uncertainty
