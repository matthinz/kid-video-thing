//
//  VideoStore.swift
//  kid-video-thing
//

import Foundation
import SQLite3

/// sqlite3_bind_text needs to know whether it may keep the pointer we hand it.
/// Swift's bridged String buffer doesn't outlive the call, so it has to copy.
private nonisolated(unsafe) let SQLITE_TRANSIENT = unsafeBitCast(
    -1, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)

/// A durable record of every video the bot has been asked to download, so a ❌
/// reaction can still find the file it belongs to after the app restarts.
actor VideoStore {
    enum Status: String {
        case downloading
        case done
        case failed
        case deleted
    }

    struct Entry {
        var id: Int64
        var channel: String
        var messageTS: String
        var url: String
        var filePath: String?
        var status: Status
        /// Nil until something has actually reported viewing figures.
        var viewCount: Int?
        var lastViewedAt: Date?
        var createdAt: Date
        var updatedAt: Date
        /// Size of the file on disk when it was last recorded.
        var sizeBytes: Int64?
        /// Emoji reacted onto this video's Slack message.
        var tags: [String] = []
    }

    /// Nil when the database couldn't be opened — every operation then becomes a
    /// no-op so a broken store degrades to the old in-memory-only behavior
    /// rather than taking the app down.
    private var db: OpaquePointer?

    static var defaultURL: URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "kid-video-thing", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "videos.sqlite")
    }

    init(url: URL = VideoStore.defaultURL) {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            log("Could not open \(url.path) — history will not be saved.")
            sqlite3_close(handle)
            return
        }
        db = handle

        let schema = """
            CREATE TABLE IF NOT EXISTS videos (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                channel TEXT NOT NULL,
                message_ts TEXT NOT NULL,
                url TEXT NOT NULL,
                file_path TEXT,
                status TEXT NOT NULL,
                view_count INTEGER,
                last_viewed_at REAL,
                size_bytes INTEGER,
                tags TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                UNIQUE (channel, message_ts, url)
            );
            CREATE INDEX IF NOT EXISTS videos_by_message ON videos (channel, message_ts);
            """
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, schema, nil, nil, &error) != SQLITE_OK {
            log("Schema failed: \(error.map { String(cString: $0) } ?? "unknown")")
            sqlite3_free(error)
            sqlite3_close(handle)
            db = nil
            return
        }

        // Databases created before viewing figures existed need the columns added.
        // ALTER fails harmlessly once they're there, so the error is the check.
        for column in [
            "view_count INTEGER", "last_viewed_at REAL", "size_bytes INTEGER", "tags TEXT",
        ] {
            sqlite3_exec(handle, "ALTER TABLE videos ADD COLUMN \(column);", nil, nil, nil)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    /// Records a download request, replacing any earlier row for the same link on
    /// the same message — a re-request after a delete starts a fresh attempt.
    @discardableResult
    func startDownload(channel: String, messageTS: String, url: String) -> Int64? {
        let sql = """
            INSERT INTO videos (channel, message_ts, url, file_path, status, created_at, updated_at)
            VALUES (?, ?, ?, NULL, ?, ?, ?)
            ON CONFLICT (channel, message_ts, url) DO UPDATE SET
                file_path = NULL, status = excluded.status, updated_at = excluded.updated_at
            RETURNING id;
            """
        guard let statement = prepare(sql) else { return nil }
        defer { sqlite3_finalize(statement) }

        let now = Date().timeIntervalSince1970
        bind(statement, 1, channel)
        bind(statement, 2, messageTS)
        bind(statement, 3, url)
        bind(statement, 4, Status.downloading.rawValue)
        sqlite3_bind_double(statement, 5, now)
        sqlite3_bind_double(statement, 6, now)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            log("Insert failed: \(lastError)")
            return nil
        }
        return sqlite3_column_int64(statement, 0)
    }

    func finish(id: Int64, status: Status, filePath: String?) {
        let sql = """
            UPDATE videos SET status = ?, file_path = ?, size_bytes = ?, updated_at = ?
            WHERE id = ?;
            """
        guard let statement = prepare(sql) else { return }
        defer { sqlite3_finalize(statement) }

        bind(statement, 1, status.rawValue)
        if let filePath {
            bind(statement, 2, filePath)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        // Measured here rather than passed in, so the size can never describe a
        // different file from the path stored beside it.
        if let size = Self.fileSize(filePath) {
            sqlite3_bind_int64(statement, 3, size)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 5, id)

        if sqlite3_step(statement) != SQLITE_DONE { log("Update failed: \(lastError)") }
    }

    /// Fills in the size for a row that predates it being recorded.
    func recordSize(id: Int64, filePath: String) {
        guard let size = Self.fileSize(filePath) else { return }
        let sql = "UPDATE videos SET size_bytes = ? WHERE id = ?;"
        guard let statement = prepare(sql) else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, size)
        sqlite3_bind_int64(statement, 2, id)
        if sqlite3_step(statement) != SQLITE_DONE { log("Size update failed: \(lastError)") }
    }

    /// Replaces the emoji recorded against one video. Membership is per video —
    /// a playlist can hold three episodes out of a message's twenty-three.
    func setTags(id: Int64, tags: [String]) {
        let sql = "UPDATE videos SET tags = ? WHERE id = ?;"
        guard let statement = prepare(sql) else { return }
        defer { sqlite3_finalize(statement) }

        bind(statement, 1, tags.sorted().joined(separator: " "))
        sqlite3_bind_int64(statement, 2, id)
        if sqlite3_step(statement) != SQLITE_DONE { log("Tag update failed: \(lastError)") }
    }

    private static func fileSize(_ path: String?) -> Int64? {
        guard let path,
            let values = try? URL(filePath: path).resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize
        else { return nil }
        return Int64(size)
    }

    private static let columns =
        """
        id, channel, message_ts, url, file_path, status, view_count, last_viewed_at, \
        created_at, updated_at, size_bytes, tags
        """

    /// Everything downloaded for one Slack message, newest first.
    func entries(channel: String, messageTS: String) -> [Entry] {
        let sql = """
            SELECT \(Self.columns) FROM videos
            WHERE channel = ? AND message_ts = ? ORDER BY id DESC;
            """
        guard let statement = prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        bind(statement, 1, channel)
        bind(statement, 2, messageTS)
        return readAll(statement)
    }

    /// The whole library, most recently touched first. Deleted rows are left out —
    /// they describe files that are deliberately gone.
    func allEntries() -> [Entry] {
        let sql = """
            SELECT \(Self.columns) FROM videos
            WHERE status != ? ORDER BY updated_at DESC;
            """
        guard let statement = prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        bind(statement, 1, Status.deleted.rawValue)
        return readAll(statement)
    }

    /// Records viewing figures for a video. Nothing populates these yet — this is
    /// where a Plex sync will write what it finds.
    func setViewStats(id: Int64, viewCount: Int?, lastViewedAt: Date?) {
        let sql = "UPDATE videos SET view_count = ?, last_viewed_at = ? WHERE id = ?;"
        guard let statement = prepare(sql) else { return }
        defer { sqlite3_finalize(statement) }

        if let viewCount {
            sqlite3_bind_int(statement, 1, Int32(viewCount))
        } else {
            sqlite3_bind_null(statement, 1)
        }
        if let lastViewedAt {
            sqlite3_bind_double(statement, 2, lastViewedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_int64(statement, 3, id)

        if sqlite3_step(statement) != SQLITE_DONE { log("View stats failed: \(lastError)") }
    }

    private func readAll(_ statement: OpaquePointer?) -> [Entry] {
        var entries: [Entry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            entries.append(
                Entry(
                    id: sqlite3_column_int64(statement, 0),
                    channel: text(statement, 1) ?? "",
                    messageTS: text(statement, 2) ?? "",
                    url: text(statement, 3) ?? "",
                    filePath: text(statement, 4),
                    status: text(statement, 5).flatMap(Status.init) ?? .failed,
                    viewCount: isNull(statement, 6) ? nil : Int(sqlite3_column_int(statement, 6)),
                    lastViewedAt: isNull(statement, 7)
                        ? nil
                        : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                    sizeBytes: isNull(statement, 10)
                        ? nil
                        : sqlite3_column_int64(statement, 10),
                    tags: (text(statement, 11) ?? "").split(separator: " ").map(String.init)))
        }
        return entries
    }

    private func isNull(_ statement: OpaquePointer?, _ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    /// A download interrupted by a quit or crash is left mid-flight in the table;
    /// on the next launch it can only be reported as failed.
    func markInterruptedDownloadsFailed() {
        let sql = "UPDATE videos SET status = ?, updated_at = ? WHERE status = ?;"
        guard let statement = prepare(sql) else { return }
        defer { sqlite3_finalize(statement) }

        bind(statement, 1, Status.failed.rawValue)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        bind(statement, 3, Status.downloading.rawValue)
        _ = sqlite3_step(statement)
    }

    // MARK: - sqlite plumbing

    private var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            log("Prepare failed: \(lastError)")
            sqlite3_finalize(statement)
            return nil
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}

private nonisolated func log(_ message: String) {
    FileHandle.standardError.write(Data("[store] \(message)\n".utf8))
}
