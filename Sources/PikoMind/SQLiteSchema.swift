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
            guard current >= 0, current <= version else {
                throw SQLiteStoreError.unsupportedSchemaVersion(current)
            }
            if current == 0 {
                try execute(compatibilitySchema, on: db)
                try execute(foundationSchema, on: db)
                try execute("INSERT INTO results_fts(results_fts) VALUES ('rebuild')", on: db)
                try execute("PRAGMA user_version = 1", on: db)
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
            id TEXT NOT NULL, createdAt REAL NOT NULL
        );
        CREATE TRIGGER turns_no_update BEFORE UPDATE ON turns BEGIN
            SELECT RAISE(ABORT, 'turns are append-only');
        END;
        CREATE TRIGGER turns_no_delete BEFORE DELETE ON turns BEGIN
            SELECT RAISE(ABORT, 'turns are append-only');
        END;
        CREATE TRIGGER turns_no_replace BEFORE INSERT ON turns
        WHEN EXISTS (SELECT 1 FROM turns WHERE lsn = new.lsn) BEGIN
            SELECT RAISE(ABORT, 'turns are append-only');
        END;
        INSERT INTO turns (id, createdAt) SELECT id, createdAt FROM results ORDER BY rowid;
        CREATE TRIGGER results_turn AFTER INSERT ON results BEGIN
            INSERT INTO turns (id, createdAt) VALUES (new.id, new.createdAt);
        END;
        CREATE TABLE facts (
            id TEXT NOT NULL PRIMARY KEY, text TEXT NOT NULL, createdAt REAL NOT NULL
        );
        CREATE TABLE entities (
            id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL,
            createdAt REAL NOT NULL
        );
        CREATE TABLE embeddings (
            ownerKind TEXT NOT NULL CHECK (ownerKind IN ('turn', 'fact', 'entity')),
            ownerID TEXT NOT NULL, model TEXT NOT NULL,
            dimensions INTEGER NOT NULL CHECK (dimensions > 0), vector BLOB NOT NULL,
            PRIMARY KEY (ownerKind, ownerID, model)
        );
        """
}
