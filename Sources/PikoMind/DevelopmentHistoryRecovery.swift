#if DEBUG
import Foundation
import SQLite3

/// Explicit developer maintenance, never part of the production migration path.
public enum DevelopmentHistoryRecovery {
    public enum Outcome: Equatable, Sendable {
        case alreadyCurrent
        case reconciled(backup: URL)
    }

    public enum Failure: Error, Equatable, Sendable {
        case unrecognizedLayout
        case experimentalMemoryPresent
        case nonDictationTurns
        case verificationFailed
    }

    public static func reconcile(path: URL) throws -> Outcome {
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(path.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI, nil)
        guard status == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(connection)
            throw SQLiteStoreError.openFailed(message)
        }
        defer { sqlite3_close(connection) }
        return try reconcile(connection, backupDirectory: path.appendingPathExtension("development-backups"))
    }

    static func reconcile(_ db: OpaquePointer, backupDirectory: URL) throws -> Outcome {
        guard sqlite3_busy_timeout(db, 5_000) == SQLITE_OK else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        try execute("PRAGMA foreign_keys = ON; BEGIN DEFERRED", on: db)
        do {
            guard let version = try values("PRAGMA user_version", on: db).first.flatMap(Int.init) else {
                throw Failure.unrecognizedLayout
            }
            if version == 1 {
                guard try SQLiteSchema.hasFinalSchema(db) else { throw Failure.unrecognizedLayout }
                try execute("COMMIT", on: db)
                return .alreadyCurrent
            }
            guard version == 2 else {
                throw SQLiteStoreError.unsupportedSchemaVersion(version)
            }
            try validateDevelopmentHistory(db)
            guard let highWater = try values(
                "SELECT coalesce(max(seq),0) FROM sqlite_sequence WHERE name='turns'", on: db
            ).first.flatMap(Int64.init) else { throw Failure.unrecognizedLayout }
            guard try values("SELECT \(highWater) >= coalesce(max(lsn),0) FROM turns", on: db) == ["1"] else {
                throw Failure.unrecognizedLayout
            }

            // Backup runs from the held read snapshot, including WAL, before any main-file write.
            let backup = try makeBackup(db, directory: backupDirectory)
            let backupURI = (backup.absoluteString + "?mode=ro").replacingOccurrences(of: "'", with: "''")
            try execute("ATTACH DATABASE '\(backupURI)' AS development_original", on: db)
            try execute("""
                CREATE TEMP TABLE development_turns AS
                    SELECT lsn,session,text,ts FROM main.turns WHERE role='assistant';
                DROP TRIGGER results_turn;
                DROP TRIGGER results_forget;
                DROP TABLE facts;
                DROP TABLE embeddings;
                DROP TABLE entities;
                DROP TABLE turns;
                """, on: db)
            try SQLiteSchema.installFoundation(db)
            try execute("""
                DELETE FROM main.turns;
                INSERT INTO main.turns(lsn,session,role,text,ts)
                    SELECT lsn,session,'user',text,ts FROM temp.development_turns ORDER BY lsn;
                DELETE FROM main.sqlite_sequence WHERE name='turns';
                INSERT INTO main.sqlite_sequence(name,seq) VALUES ('turns',\(highWater));
                """, on: db)
            for table in ["results", "edits", "items"] {
                guard try values("""
                    SELECT NOT EXISTS (
                        SELECT rowid,* FROM main.\(table)
                        EXCEPT SELECT rowid,* FROM development_original.\(table)
                    ) AND NOT EXISTS (
                        SELECT rowid,* FROM development_original.\(table)
                        EXCEPT SELECT rowid,* FROM main.\(table)
                    )
                    """, on: db) == ["1"] else { throw Failure.verificationFailed }
            }
            guard try SQLiteSchema.hasFinalSchema(db),
                  try values("PRAGMA quick_check", on: db) == ["ok"],
                  try values("PRAGMA foreign_key_check", on: db).isEmpty,
                  try values("""
                    SELECT NOT EXISTS (
                        SELECT lsn,session,text,ts FROM main.turns
                        EXCEPT SELECT lsn,session,text,ts FROM temp.development_turns
                    ) AND NOT EXISTS (
                        SELECT lsn,session,text,ts FROM temp.development_turns
                        EXCEPT SELECT lsn,session,text,ts FROM main.turns
                    ) AND NOT EXISTS (SELECT 1 FROM main.turns WHERE role!='user')
                    """, on: db) == ["1"] else { throw Failure.verificationFailed }
            try execute("INSERT INTO results_fts(results_fts,rank) VALUES ('integrity-check',1)", on: db)
            try execute("DROP TABLE temp.development_turns; COMMIT", on: db)
            return .reconciled(backup: backup)
        } catch {
            let recoveryError = error
            if sqlite3_get_autocommit(db) == 0 {
                do {
                    try execute("ROLLBACK", on: db)
                } catch {
                    throw SQLiteStoreError.rollbackFailed(
                        migration: String(describing: recoveryError), rollback: String(describing: error))
                }
            }
            throw recoveryError
        }
    }

    private static func validateDevelopmentHistory(_ db: OpaquePointer) throws {
        let tables = [
            "results", "results_fts", "results_fts_data", "results_fts_idx",
            "results_fts_docsize", "results_fts_config", "items", "edits",
            "turns", "entities", "facts", "embeddings",
        ]
        let triggers = ["results_ai", "results_ad", "turns_no_update", "turns_no_replace",
                        "results_turn", "results_forget"]
        let expected = (tables.map { "table:\($0)" } + triggers.map { "trigger:\($0)" }
                        + ["index:facts_key", "index:turns_capture"]).sorted()
        guard try values("""
            SELECT type||':'||name FROM sqlite_schema WHERE name NOT GLOB 'sqlite_*' ORDER BY 1
            """, on: db) == expected,
              try values("PRAGMA quick_check", on: db) == ["ok"] else { throw Failure.unrecognizedLayout }
        let columns = [
            "results": "id,raw,shipped,route,profile,createdAt,firstWordMS,transcribeMS,brainMS",
            "results_fts": "raw,shipped",
            "items": "id,kind,text,due,createdAt",
            "edits": "raw,shipped,final,profile,createdAt",
            "turns": "lsn,id,createdAt,session,role,text,ts",
            "entities": "id,name,kind,createdAt,aliases,contactID",
            "facts": "id,text,createdAt,key,value,lsn,sourceTurn,confidence,lastUsed,entityID",
            "embeddings": "ownerKind,ownerID,model,dimensions,vector,encoding",
        ]
        for (table, names) in columns {
            guard try values("SELECT group_concat(name,',') FROM pragma_table_info('\(table)')", on: db)
                    == [names] else { throw Failure.unrecognizedLayout }
        }
        guard try values("""
            SELECT (SELECT count(*) FROM facts)+(SELECT count(*) FROM entities)
                +(SELECT count(*) FROM embeddings)
            """, on: db) == ["0"] else { throw Failure.experimentalMemoryPresent }
        guard try values("""
            SELECT (SELECT count(*) FROM turns)=2*(SELECT count(*) FROM results)
                AND NOT EXISTS (
                    SELECT 1 FROM results r WHERE
                    (SELECT count(*) FROM turns t WHERE t.id=r.id AND t.session=r.id
                        AND t.createdAt=r.createdAt AND t.ts=r.createdAt
                        AND t.role='user' AND t.text=r.raw)!=1
                    OR (SELECT count(*) FROM turns t WHERE t.id=r.id AND t.session=r.id
                        AND t.createdAt=r.createdAt AND t.ts=r.createdAt
                        AND t.role='assistant' AND t.text=r.shipped)!=1
                )
            """, on: db) == ["1"] else { throw Failure.nonDictationTurns }
    }

    private static func makeBackup(_ source: OpaquePointer, directory: URL) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var excludedDirectory = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try excludedDirectory.setResourceValues(resources)
        let snapshotDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false)
        let path = snapshotDirectory.appendingPathComponent("original.sqlite")
        var destination: OpaquePointer?
        let status = sqlite3_open_v2(path.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard status == SQLITE_OK, let destination else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "backup open failed"
            sqlite3_close(destination)
            throw SQLiteStoreError.openFailed(message)
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(destination)))
        }
        let copied = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard copied == SQLITE_DONE, finished == SQLITE_OK,
              try values("PRAGMA quick_check", on: destination) == ["ok"],
              try values("PRAGMA user_version", on: destination) == ["2"] else {
            throw Failure.verificationFailed
        }
        return path
    }

    private static func execute(_ sql: String, on db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func values(_ sql: String, on db: OpaquePointer) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else { throw Failure.verificationFailed }
            result.append(String(cString: value))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw SQLiteStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
        return result
    }
}
#endif
