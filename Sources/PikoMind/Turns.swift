import Foundation
import SQLite3

/// One thing said or done, in the order it happened. The log only grows: an LSN is never reused,
/// even after its turn is forgotten, so anything that points at an LSN can trust it.
public struct Turn: Sendable, Equatable {
    public enum Role: String, Sendable, CaseIterable {
        case user, assistant, tool
    }

    public var lsn: Int64
    public var session: String
    public var role: Role
    public var text: String
    public var createdAt: Date
    /// What produced the turn, such as a `CaptureResult` id, so forgetting that also forgets this.
    public var sourceID: String?
}

extension MindDatabase {
    /// Session name for turns that came from dictation.
    public static let dictationSession = "dictation"

    @discardableResult
    public func appendTurn(session: String, role: Turn.Role, text: String,
                           createdAt: Date = Date(), sourceID: String? = nil) throws -> Int64 {
        let sql = "INSERT INTO turns (session, role, text, createdAt, sourceID) VALUES (?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MindError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, session, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, role.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, text, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, createdAt.timeIntervalSince1970)
        if let sourceID {
            sqlite3_bind_text(stmt, 5, sourceID, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw MindError.stepFailed(lastError) }
        return sqlite3_last_insert_rowid(handle)
    }

    /// The last `last` turns of a session, oldest first.
    public func turns(session: String, last: Int) throws -> [Turn] {
        let sql = """
        SELECT lsn, session, role, text, createdAt, sourceID FROM turns
        WHERE session = ? ORDER BY lsn DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MindError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, session, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(clamping: last))

        var turns: [Turn] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let sessionC = sqlite3_column_text(stmt, 1),
                  let roleC = sqlite3_column_text(stmt, 2),
                  let textC = sqlite3_column_text(stmt, 3),
                  let role = Turn.Role(rawValue: String(cString: roleC)) else { continue }
            let sourceID = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            turns.append(Turn(lsn: sqlite3_column_int64(stmt, 0), session: String(cString: sessionC),
                              role: role, text: String(cString: textC),
                              createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                              sourceID: sourceID))
        }
        return turns.reversed()
    }

    /// Removes every turn produced by `sourceID`, with its search entry and vector.
    public func forgetTurns(sourceID: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "DELETE FROM turns WHERE sourceID = ?", -1, &stmt, nil) == SQLITE_OK else {
            throw MindError.prepareFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sourceID, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw MindError.stepFailed(lastError) }
    }
}
