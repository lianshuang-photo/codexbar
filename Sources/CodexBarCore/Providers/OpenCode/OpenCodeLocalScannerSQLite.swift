import Foundation

#if canImport(SQLite3)
import SQLite3
#endif

/// Read-only SQLite reader for the OpenCode Desktop App's `opencode.db`.
///
/// The schema is a single `message` table with a JSON `data` column. The
/// query mirrors the one used by MyCCusage's `ccusage-collector` package
/// (`packages/ccusage-collector/src/collector.ts`, `readOpencodeDB`):
///
///     SELECT json_extract(data, '$.time.created') AS ts,
///            json_extract(data, '$.modelID')      AS model,
///            COALESCE(json_extract(data, '$.tokens.input'), 0)        AS inp,
///            COALESCE(json_extract(data, '$.tokens.output'), 0)       AS out,
///            COALESCE(json_extract(data, '$.tokens.cache.read'), 0)   AS cr,
///            COALESCE(json_extract(data, '$.tokens.cache.write'), 0)  AS cw
///       FROM message
///      WHERE json_extract(data, '$.role') = 'assistant'
///        AND json_extract(data, '$.tokens.total') > 0;
///
/// The connection is opened with `SQLITE_OPEN_READONLY` so the user's
/// OpenCode database file is never modified.
///
/// On platforms without `SQLite3` (Linux Swift toolchain), this fallback
/// is stubbed and `readMessages` returns an empty slice — equivalent to
/// "no opencode.db found".
enum OpenCodeLocalScannerSQLite {
    enum SQLiteError: Error {
        case openFailed(String)
        case prepareFailed(String)
        case unsupportedPlatform
    }

    #if canImport(SQLite3)
    static func readMessages(dbPath: String) throws -> [OpenCodeLoadedEntry] {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK else {
            let detail = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw SQLiteError.openFailed(detail)
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT
          json_extract(data, '$.id')               AS msg_id,
          json_extract(data, '$.time.created')     AS ts,
          json_extract(data, '$.modelID')          AS model,
          COALESCE(json_extract(data, '$.tokens.input'), 0)       AS inp,
          COALESCE(json_extract(data, '$.tokens.output'), 0)      AS out,
          COALESCE(json_extract(data, '$.tokens.cache.read'), 0)  AS cr,
          COALESCE(json_extract(data, '$.tokens.cache.write'), 0) AS cw
        FROM message
        WHERE json_extract(data, '$.role') = 'assistant'
          AND json_extract(data, '$.tokens.total') > 0
        """

        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            let detail = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.prepareFailed(detail)
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [OpenCodeLoadedEntry] = []
        var seenIds: Set<String> = []
        var fallbackCounter = 0

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let modelCStr = sqlite3_column_text(stmt, 2) else { continue }
            let model = String(cString: modelCStr)
            if model.isEmpty { continue }

            // `ts` may be stored either as INTEGER or as TEXT inside the JSON.
            // Read it as int64 first; if zero, try parsing the text form.
            var createdMs = sqlite3_column_int64(stmt, 1)
            if createdMs == 0, let cStr = sqlite3_column_text(stmt, 1) {
                createdMs = Int64(String(cString: cStr)) ?? 0
            }
            if createdMs == 0 { continue }

            let messageId: String
            if let idCStr = sqlite3_column_text(stmt, 0) {
                messageId = String(cString: idCStr)
            } else {
                fallbackCounter += 1
                messageId = "opencode-sqlite-\(fallbackCounter)"
            }

            if !messageId.isEmpty {
                if seenIds.contains(messageId) { continue }
                seenIds.insert(messageId)
            }

            let input = Int(sqlite3_column_int64(stmt, 3))
            let output = Int(sqlite3_column_int64(stmt, 4))
            let cacheRead = Int(sqlite3_column_int64(stmt, 5))
            let cacheWrite = Int(sqlite3_column_int64(stmt, 6))

            if input == 0, output == 0 { continue }

            rows.append(OpenCodeLoadedEntry(
                messageId: messageId,
                timestamp: Date(timeIntervalSince1970: Double(createdMs) / 1000.0),
                model: model,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheCreationTokens: cacheWrite,
                costUSD: nil))
        }

        return rows
    }
    #else
    /// Linux stub: SQLite3 is not part of the Swift toolchain on Linux,
    /// so the Desktop App fallback is unsupported there. Return an empty
    /// slice so callers behave as if no `opencode.db` was found.
    static func readMessages(dbPath: String) throws -> [OpenCodeLoadedEntry] {
        _ = dbPath
        return []
    }
    #endif
}
