import CryptoKit
import Foundation
import SQLite3

/// Remembers files that could not be shrunk any further (by content and settings), so dropping
/// the same folder again doesn't re-run every tool on files that are already optimal.
actor ResultsCache {
    private var db: OpaquePointer?

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = caches.appending(path: Bundle.main.bundleIdentifier ?? "fm.beard.Imager", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "Results.db").path
        var handle: OpaquePointer?
        if sqlite3_open(path, &handle) == SQLITE_OK, let handle {
            db = handle
            sqlite3_exec(handle, "CREATE TABLE IF NOT EXISTS results(hash BLOB NOT NULL PRIMARY KEY, size INTEGER NOT NULL, seen REAL NOT NULL)", nil, nil, nil)
        } else {
            if let handle { sqlite3_close(handle) }
            db = nil
        }
    }

    /// Hashes the settings that shaped a run together with the file's bytes.
    nonisolated static func key(settings: String, data: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(settings.utf8))
        hasher.update(data: data)
        return Data(hasher.finalize().prefix(16))
    }

    func contains(_ key: Data) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM results WHERE hash = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return false }
        return key.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func rememberUnoptimizable(_ key: Data, size: Int) {
        guard let db else { return }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO results(hash, size, seen) VALUES(?, ?, ?)", -1, &statement, nil) == SQLITE_OK else { return }
        key.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int64(statement, 2, Int64(size))
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            _ = sqlite3_step(statement)
        }
    }

    func forgetAll() {
        guard let db else { return }
        sqlite3_exec(db, "DELETE FROM results", nil, nil, nil)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }
}
