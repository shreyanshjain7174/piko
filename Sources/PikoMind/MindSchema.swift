/// Ordered schema steps. Index `n` takes the file from version `n` to `n + 1`.
/// Append only: never edit a step that has shipped, add a new one.
enum MindSchema {
    static let migrations: [String] = [v1CaptureHistory, v2Mind]

    /// The capture-history tables PikoMemory created before the file was versioned. `IF NOT
    /// EXISTS` throughout, because files from those builds are at user_version 0 and already
    /// hold these tables.
    static let v1CaptureHistory = """
    CREATE TABLE IF NOT EXISTS results (
        id TEXT NOT NULL UNIQUE, raw TEXT NOT NULL, shipped TEXT NOT NULL,
        route TEXT NOT NULL, profile TEXT NOT NULL, createdAt REAL NOT NULL,
        firstWordMS INTEGER NOT NULL, transcribeMS INTEGER NOT NULL, brainMS INTEGER NOT NULL
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS results_fts USING fts5(
        raw, shipped, content='results', content_rowid='rowid'
    );
    CREATE TRIGGER IF NOT EXISTS results_ai AFTER INSERT ON results BEGIN
        INSERT INTO results_fts(rowid, raw, shipped) VALUES (new.rowid, new.raw, new.shipped);
    END;
    CREATE TRIGGER IF NOT EXISTS results_ad AFTER DELETE ON results BEGIN
        INSERT INTO results_fts(results_fts, rowid, raw, shipped)
        VALUES ('delete', old.rowid, old.raw, old.shipped);
    END;
    CREATE TABLE IF NOT EXISTS items (
        id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, text TEXT NOT NULL,
        due REAL, createdAt REAL NOT NULL
    );
    CREATE TABLE IF NOT EXISTS edits (
        raw TEXT NOT NULL, shipped TEXT NOT NULL, final TEXT NOT NULL,
        profile TEXT NOT NULL, createdAt REAL NOT NULL
    );
    """

    /// The personal memory, shaped like zerodb: an append-only turn log addressed by LSN, keyed
    /// facts that point back at the turn they came from, entities with aliases, and one vector
    /// per remembered thing. A fact outlives the turn it was learned from (`ON DELETE SET NULL`)
    /// because old raw turns are pruned once consolidated; forgetting a fact is its own act.
    /// Existing dictations are backfilled as user turns so nothing the
    /// user already said is lost to the new recall path.
    static let v2Mind = """
    CREATE TABLE turns (
        lsn INTEGER PRIMARY KEY AUTOINCREMENT,
        session TEXT NOT NULL, role TEXT NOT NULL, text TEXT NOT NULL,
        createdAt REAL NOT NULL, sourceID TEXT
    );
    CREATE INDEX turns_session ON turns(session, lsn);
    CREATE INDEX turns_source ON turns(sourceID);
    CREATE VIRTUAL TABLE turns_fts USING fts5(text, content='turns', content_rowid='lsn');
    CREATE TRIGGER turns_ai AFTER INSERT ON turns BEGIN
        INSERT INTO turns_fts(rowid, text) VALUES (new.lsn, new.text);
    END;
    CREATE TRIGGER turns_ad AFTER DELETE ON turns BEGIN
        INSERT INTO turns_fts(turns_fts, rowid, text) VALUES ('delete', old.lsn, old.text);
        DELETE FROM embeddings WHERE owner = 'turn' AND ownerID = CAST(old.lsn AS TEXT);
    END;

    CREATE TABLE entities (
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, createdAt REAL NOT NULL
    );
    CREATE TABLE entity_aliases (
        entityID TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
        alias TEXT NOT NULL COLLATE NOCASE,
        PRIMARY KEY (entityID, alias)
    );

    CREATE TABLE facts (
        key TEXT PRIMARY KEY, value TEXT NOT NULL, lsn INTEGER NOT NULL,
        sourceLSN INTEGER REFERENCES turns(lsn) ON DELETE SET NULL,
        entityID TEXT REFERENCES entities(id) ON DELETE SET NULL,
        confidence REAL NOT NULL DEFAULT 1,
        createdAt REAL NOT NULL, lastUsedAt REAL
    );
    CREATE INDEX facts_entity ON facts(entityID);
    CREATE TRIGGER facts_ad AFTER DELETE ON facts BEGIN
        DELETE FROM embeddings WHERE owner = 'fact' AND ownerID = old.key;
    END;

    CREATE TABLE embeddings (
        owner TEXT NOT NULL, ownerID TEXT NOT NULL,
        model TEXT NOT NULL, dim INTEGER NOT NULL, vector BLOB NOT NULL,
        PRIMARY KEY (owner, ownerID)
    );

    INSERT INTO turns (session, role, text, createdAt, sourceID)
    SELECT 'dictation', 'user', shipped, createdAt, id FROM results ORDER BY createdAt, rowid;
    """
}
