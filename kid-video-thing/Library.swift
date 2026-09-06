//
//  Library.swift
//  kid-video-thing
//

import Foundation
import Observation

/// A Slack message a video was asked for in.
struct SlackMessage: Hashable {
    var channel: String
    var timestamp: String
}

/// One video, as the main list shows it.
///
/// A video can hold several database rows: the same YouTube video posted twice
/// arrives as `youtu.be/X`, `watch?v=X`, `watch?v=X&t=2s` — three URLs, one file
/// on disk. Rows are collapsed by video ID, so the list shows the file once, its
/// size counts once, and deleting it accounts for every row and message involved.
struct LibraryVideo: Identifiable {
    /// The YouTube video ID, or the URL when there isn't one to extract.
    var id: String

    /// Every database row this collapses, newest first.
    var recordIDs: [Int64] = []
    /// Every Slack message that asked for it.
    var messages: [SlackMessage] = []
    var url: String

    var filePath: String?
    var status: VideoStore.Status
    /// Nil until viewing figures have been gathered from somewhere.
    var viewCount: Int?
    var lastViewedAt: Date?
    /// Set while this video is in the download queue or running.
    var download: Download?

    // Resolved when the library is built rather than read from the view: rows are
    // re-rendered constantly, and hitting the filesystem in `body` is a bad habit.
    var fileExists = false
    var posterPath: String?
    /// When the video actually landed on disk. Taken from the file itself, which
    /// survives database churn — a repaired path or a re-sync rewrites the row's
    /// own timestamps, so those would shuffle the list for no real reason.
    var downloadedAt = Date.distantPast
    /// Size on disk, falling back to what was last recorded if the file is gone.
    var sizeBytes: Int64?
    /// Emoji reacted onto this video's Slack message.
    var tags: [String] = []
    /// The name yt-dlp gave this video, once its title has been cleaned up.
    /// Nil means the name on disk is still the original one.
    var originalName: String?

    /// True once the title has been through a cleanup, so the row can offer to
    /// put the original back.
    var isRenamed: Bool { originalName != nil }

    var file: URL? { filePath.map { URL(filePath: $0) } }
    var posterURL: URL? { posterPath.map { URL(filePath: $0) } }

    /// A video we believe we have but can't find on disk.
    var isMissing: Bool { status == .done && !fileExists }

    var isDownloading: Bool {
        download?.isActive ?? false
    }

    /// The filename, tidied into something readable: yt-dlp writes
    /// `Some_Show_Title [abc123XYZ_9].webm`, which reads badly in a list.
    var title: String {
        guard let file else { return url }
        var name = file.deletingPathExtension().lastPathComponent
        if let bracket = name.range(of: " [", options: .backwards) {
            name = String(name[name.startIndex..<bracket.lowerBound])
        }
        return name.replacingOccurrences(of: "_", with: " ")
    }
}

/// The library the main list shows: everything on record, with any download
/// currently working on it attached.
///
/// The database is the source of truth so the list survives restarts, but a
/// just-queued download won't have been written yet — those are folded in from
/// the download manager so a new item appears the moment it's added.
@MainActor
@Observable
final class Library {
    private(set) var videos: [LibraryVideo] = []

    private let store: VideoStore
    private let downloads: DownloadManager

    init(store: VideoStore, downloads: DownloadManager) {
        self.store = store
        self.downloads = downloads
    }

    func refresh() async {
        let entries = await store.allEntries()
        let active = downloads.downloads

        // Entries arrive newest first, so the first row seen for a video supplies
        // its details and later ones only contribute their row id and message.
        // Playlists are skipped — a playlist is a container whose members each
        // have a row of their own, so it is not a video file.
        var byVideo: [String: LibraryVideo] = [:]
        var order: [String] = []

        for entry in entries where !YouTubeLink.isPlaylist(entry.url) {
            let key = Self.key(for: entry.url)
            let message = SlackMessage(channel: entry.channel, timestamp: entry.messageTS)

            if byVideo[key] != nil {
                byVideo[key]?.recordIDs.append(entry.id)
                if !message.channel.isEmpty, byVideo[key]?.messages.contains(message) == false {
                    byVideo[key]?.messages.append(message)
                }
                continue
            }

            let file = Self.fileInfo(entry.filePath)
            byVideo[key] = LibraryVideo(
                id: key,
                recordIDs: [entry.id],
                messages: message.channel.isEmpty ? [] : [message],
                url: entry.url,
                filePath: entry.filePath,
                status: entry.status,
                viewCount: entry.viewCount,
                lastViewedAt: entry.lastViewedAt,
                download: active.first { Self.key(for: $0.videoURL) == key },
                fileExists: file.exists,
                posterPath: Self.poster(for: entry.filePath),
                downloadedAt: file.modified ?? entry.updatedAt,
                sizeBytes: file.size ?? entry.sizeBytes,
                tags: entry.tags,
                originalName: entry.originalName)
            order.append(key)
        }

        // Anything queued in the last instant has no row yet.
        for download in active {
            let key = Self.key(for: download.videoURL)
            guard byVideo[key] == nil else { continue }
            let file = Self.fileInfo(download.destination?.path)
            byVideo[key] = LibraryVideo(
                id: key,
                recordIDs: download.recordID.map { [$0] } ?? [],
                url: download.videoURL,
                filePath: download.destination?.path,
                status: .downloading,
                download: download,
                fileExists: file.exists,
                posterPath: Self.poster(for: download.destination?.path),
                downloadedAt: Date(),
                sizeBytes: file.size)
            order.insert(key, at: 0)
        }

        // Whatever is downloading stays pinned at the top — it's the thing
        // happening right now — and everything else sorts by how it's been used.
        let all = order.compactMap { byVideo[$0] }.sorted(by: Self.isOrderedBefore)
        videos = all.filter(\.isDownloading) + all.filter { !$0.isDownloading }
    }

    /// What identifies a video across the several URLs that can name it.
    private static func key(for url: String) -> String {
        CoverArt.videoID(from: url) ?? url
    }

    /// Most recently watched first, then most recently downloaded. Videos nobody
    /// has played sort below every video that has been, however long ago.
    private static func isOrderedBefore(_ a: LibraryVideo, _ b: LibraryVideo) -> Bool {
        if let left = a.lastViewedAt, let right = b.lastViewedAt, left != right {
            return left > right
        }
        if (a.lastViewedAt == nil) != (b.lastViewedAt == nil) {
            return a.lastViewedAt != nil
        }
        return a.downloadedAt > b.downloadedAt
    }

    /// Existence, modification date and size in a single trip to the filesystem.
    private static func fileInfo(
        _ path: String?
    ) -> (exists: Bool, modified: Date?, size: Int64?) {
        guard let path,
            let values = try? URL(filePath: path).resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return (false, nil, nil) }
        return (true, values.contentModificationDate, values.fileSize.map(Int64.init))
    }

    private static func poster(for path: String?) -> String? {
        guard let path else { return nil }
        let poster = MediaLayout.posterURL(for: URL(filePath: path))
        return FileManager.default.fileExists(atPath: poster.path) ? poster.path : nil
    }
}
