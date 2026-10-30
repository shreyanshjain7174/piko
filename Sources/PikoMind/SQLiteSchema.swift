import SQLite3

/// Version zero is the shipped, unversioned history database. Never replace that file.
enum SQLiteSchema {
    static let version = 1

    static func migrate(_ db: OpaquePointer) throws {
        // Acquire the write lock before reading the version so simultaneous openers cannot
        // both backfill. DDL, FTS rebuild, backfill, and user_version commit together.
        try execute("BEGIN IMMEDIATE", on: db)
        do {
            let current = try currentVersion(db)
            switch current {
            case 0:
                try installFoundation(db)
            case version:
                // Version one means only the final schema, never an unreleased PR layout.
                guard try hasFinalSchema(db) else {
                    throw SQLiteStoreError.unsupportedSchemaVersion(current)
                }
            default:
                throw SQLiteStoreError.unsupportedSchemaVersion(current)
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

    static func installFoundation(_ db: OpaquePointer) throws {
        try execute(compatibilitySchema, on: db)
        try execute(foundationSchema, on: db)
        try execute(contentTriggers, on: db)
        try execute("INSERT INTO results_fts(results_fts) VALUES ('rebuild')", on: db)
        try execute("PRAGMA user_version = 1", on: db)
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

    static func hasFinalSchema(_ db: OpaquePointer) throws -> Bool {
        let sql = """
            SELECT
                (SELECT group_concat(name, ',') FROM
                    (SELECT name FROM pragma_table_info('turns') ORDER BY cid))
                    = 'lsn,session,role,text,ts'
                AND (SELECT group_concat(name, ',') FROM
                    (SELECT name FROM pragma_table_info('facts') ORDER BY cid))
                    = 'key,value,lsn,sourceTurn,confidence,lastUsed,entityID'
                AND EXISTS (SELECT 1 FROM pragma_table_info('facts')
                    WHERE name = 'key' AND type = 'TEXT' AND "notnull" = 1
                    AND pk = 1 AND dflt_value IS NULL)
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_column_int(statement, 0) == 1
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
            session TEXT NOT NULL,
            role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'tool', 'system')),
            text TEXT NOT NULL, ts REAL NOT NULL
        );
        INSERT INTO turns (session, role, text, ts)
        SELECT id, 'user', shipped, createdAt FROM results ORDER BY rowid;
        CREATE TABLE entities (
            id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL,
            createdAt REAL NOT NULL, aliases TEXT NOT NULL DEFAULT '[]', contactID TEXT
        );
        CREATE TABLE facts (
            key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL,
            lsn INTEGER NOT NULL DEFAULT 0 CHECK (lsn >= 0),
            sourceTurn INTEGER REFERENCES turns(lsn) ON DELETE SET NULL,
            confidence REAL NOT NULL DEFAULT 0 CHECK (confidence BETWEEN 0 AND 1),
            lastUsed REAL NOT NULL DEFAULT 0,
            entityID TEXT REFERENCES entities(id) ON DELETE SET NULL
        );
        CREATE TABLE embeddings (
            ownerKind TEXT NOT NULL CHECK (ownerKind IN ('turn', 'fact', 'entity')),
            ownerID TEXT NOT NULL, model TEXT NOT NULL,
            dimensions INTEGER NOT NULL CHECK (dimensions > 0), vector BLOB NOT NULL,
            encoding TEXT NOT NULL DEFAULT 'float16' CHECK (encoding IN ('float16', 'int8')),
            PRIMARY KEY (ownerKind, ownerID, model)
        );
        """

    private static let contentTriggers = """
        CREATE INDEX turns_session ON turns (session);
        CREATE TRIGGER turns_no_update BEFORE UPDATE ON turns BEGIN
            SELECT RAISE(ABORT, 'turns are append-only');
        END;
        CREATE TRIGGER turns_no_replace BEFORE INSERT ON turns
        WHEN EXISTS (SELECT 1 FROM turns WHERE lsn = new.lsn) BEGIN
            SELECT RAISE(ABORT, 'turns are append-only');
        END;
        CREATE TRIGGER results_turn AFTER INSERT ON results BEGIN
            INSERT INTO turns (session, role, text, ts)
            VALUES (new.id, 'user', new.shipped, new.createdAt);
        END;
        CREATE TRIGGER results_forget AFTER DELETE ON results BEGIN
            DELETE FROM turns WHERE session = old.id;
        END;
        CREATE TRIGGER turns_forget_embeddings AFTER DELETE ON turns BEGIN
            DELETE FROM embeddings WHERE ownerKind = 'turn' AND ownerID = CAST(old.lsn AS TEXT);
        END;
        CREATE TRIGGER facts_forget_embeddings AFTER DELETE ON facts BEGIN
            DELETE FROM embeddings WHERE ownerKind = 'fact' AND ownerID = old.key;
        END;
        CREATE TRIGGER entities_forget_embeddings AFTER DELETE ON entities BEGIN
            DELETE FROM embeddings WHERE ownerKind = 'entity' AND ownerID = old.id;
        END;
        """
}
