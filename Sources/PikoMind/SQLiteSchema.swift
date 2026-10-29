import SQLite3

/// Version zero is the shipped, unversioned history database. Never replace that file.
enum SQLiteSchema {
    static let version = 2

    static func migrate(_ db: OpaquePointer) throws {
        // Acquire the write lock before reading the version so simultaneous openers cannot
        // both backfill. DDL, FTS rebuild, backfill, and user_version commit together.
        try execute("BEGIN IMMEDIATE", on: db)
        do {
            let current = try currentVersion(db)
            guard current >= 0, current <= version else {
                throw SQLiteStoreError.unsupportedSchemaVersion(current)
            }
            if current == 0 {
                try execute(compatibilitySchema, on: db)
                try execute(foundationSchema, on: db)
            } else if current == 1 {
                try execute(upgradeVersionOne, on: db)
            }
            if current < version {
                try execute(turnTriggers, on: db)
                try execute("INSERT INTO results_fts(results_fts) VALUES ('rebuild')", on: db)
                try execute("PRAGMA user_version = 2", on: db)
            }
            try execute("COMMIT", on: db)
        } catch {
            let migrationError = error
            do {
                try execute("ROLLBACK", on: db)
            } catch {
                throw SQLiteStoreError.rollbackFailed(
                    migration: String(describing: migrationError), rollback: String(describing: error)
                )
            }
            throw migrationError
        }
    }

    private static func currentVersion(_ db: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func execute(_ sql: String, on db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static let compatibilitySchema = """
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

    private static let foundationSchema = """
        CREATE TABLE turns (
            lsn INTEGER PRIMARY KEY AUTOINCREMENT,
            id TEXT NOT NULL, createdAt REAL NOT NULL,
            session TEXT NOT NULL,
            role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'tool', 'system')),
            text TEXT NOT NULL, ts REAL NOT NULL
        );
        INSERT INTO turns (id, createdAt, session, role, text, ts)
        SELECT r.id, r.createdAt, r.id, roles.role,
               CASE roles.role WHEN 'user' THEN r.raw ELSE r.shipped END, r.createdAt
        FROM results r CROSS JOIN (
            SELECT 0 AS position, 'user' AS role UNION ALL SELECT 1, 'assistant'
        ) roles ORDER BY r.rowid, roles.position;
        CREATE TABLE entities (
            id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL,
            createdAt REAL NOT NULL, aliases TEXT NOT NULL DEFAULT '[]', contactID TEXT
        );
        CREATE TABLE facts (
            id TEXT NOT NULL PRIMARY KEY, text TEXT NOT NULL, createdAt REAL NOT NULL,
            key TEXT NOT NULL DEFAULT '', value TEXT NOT NULL DEFAULT '',
            lsn INTEGER NOT NULL DEFAULT 0 CHECK (lsn >= 0),
            sourceTurn INTEGER REFERENCES turns(lsn) ON DELETE SET NULL,
            confidence REAL NOT NULL DEFAULT 0 CHECK (confidence BETWEEN 0 AND 1),
            lastUsed REAL NOT NULL DEFAULT 0,
            entityID TEXT REFERENCES entities(id) ON DELETE SET NULL
        );
        CREATE UNIQUE INDEX facts_key ON facts (key);
        CREATE TABLE embeddings (
            ownerKind TEXT NOT NULL CHECK (ownerKind IN ('turn', 'fact', 'entity')),
            ownerID TEXT NOT NULL, model TEXT NOT NULL,
            dimensions INTEGER NOT NULL CHECK (dimensions > 0), vector BLOB NOT NULL,
            encoding TEXT NOT NULL DEFAULT 'float16' CHECK (encoding IN ('float16', 'int8')),
            PRIMARY KEY (ownerKind, ownerID, model)
        );
        """

    /// Keep committed v1 LSNs and old columns/data. Only metadata for already-forgotten
    /// captures is discarded; active envelopes become user turns and replies append.
    private static let upgradeVersionOne = """
        DROP TRIGGER turns_no_update;
        DROP TRIGGER turns_no_delete;
        DROP TRIGGER turns_no_replace;
        DROP TRIGGER results_turn;
        ALTER TABLE turns ADD COLUMN session TEXT NOT NULL DEFAULT '';
        ALTER TABLE turns ADD COLUMN role TEXT NOT NULL DEFAULT 'user'
            CHECK (role IN ('user', 'assistant', 'tool', 'system'));
        ALTER TABLE turns ADD COLUMN text TEXT NOT NULL DEFAULT '';
        ALTER TABLE turns ADD COLUMN ts REAL NOT NULL DEFAULT 0;
        DELETE FROM turns WHERE lsn NOT IN (
            SELECT max(t.lsn) FROM turns t JOIN results r
            ON r.id = t.id AND r.createdAt = t.createdAt GROUP BY r.id
        );
        UPDATE turns SET session = id, role = 'user', ts = createdAt,
            text = (SELECT raw FROM results WHERE results.id = turns.id);
        INSERT INTO turns (id, createdAt, session, role, text, ts)
        SELECT r.id, r.createdAt, r.id, 'user', r.raw, r.createdAt FROM results r
        WHERE NOT EXISTS (SELECT 1 FROM turns t WHERE t.id = r.id) ORDER BY r.rowid;
        INSERT INTO turns (id, createdAt, session, role, text, ts)
        SELECT id, createdAt, id, 'assistant', shipped, createdAt FROM results ORDER BY rowid;
        ALTER TABLE facts ADD COLUMN key TEXT NOT NULL DEFAULT '';
        ALTER TABLE facts ADD COLUMN value TEXT NOT NULL DEFAULT '';
        ALTER TABLE facts ADD COLUMN lsn INTEGER NOT NULL DEFAULT 0 CHECK (lsn >= 0);
        ALTER TABLE facts ADD COLUMN sourceTurn INTEGER REFERENCES turns(lsn) ON DELETE SET NULL;
        ALTER TABLE facts ADD COLUMN confidence REAL NOT NULL DEFAULT 0 CHECK (confidence BETWEEN 0 AND 1);
        ALTER TABLE facts ADD COLUMN lastUsed REAL NOT NULL DEFAULT 0;
        ALTER TABLE facts ADD COLUMN entityID TEXT REFERENCES entities(id) ON DELETE SET NULL;
        UPDATE facts SET key = id, value = text, lastUsed = createdAt;
        CREATE UNIQUE INDEX facts_key ON facts (key);
        ALTER TABLE entities ADD COLUMN aliases TEXT NOT NULL DEFAULT '[]';
        ALTER TABLE entities ADD COLUMN contactID TEXT;
        ALTER TABLE embeddings ADD COLUMN encoding TEXT NOT NULL DEFAULT 'float16'
            CHECK (encoding IN ('float16', 'int8'));
        """

    private static let turnTriggers = """
        CREATE INDEX turns_capture ON turns (id);
        CREATE TRIGGER turns_no_update BEFORE UPDATE ON turns BEGIN
            SELECT RAISE(ABORT, 'turns are append-only');
        END;
        CREATE TRIGGER turns_no_replace BEFORE INSERT ON turns
        WHEN EXISTS (SELECT 1 FROM turns WHERE lsn = new.lsn) BEGIN
            SELECT RAISE(ABORT, 'turns are append-only');
        END;
        CREATE TRIGGER results_turn AFTER INSERT ON results BEGIN
            INSERT INTO turns (id, createdAt, session, role, text, ts)
            VALUES (new.id, new.createdAt, new.id, 'user', new.raw, new.createdAt),
                   (new.id, new.createdAt, new.id, 'assistant', new.shipped, new.createdAt);
        END;
        CREATE TRIGGER results_forget AFTER DELETE ON results BEGIN
            DELETE FROM turns WHERE id = old.id;
        END;
        """
}
