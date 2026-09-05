//
//  Library.swift
//  kid-video-thing
//

import Foundation
import Observation

/// One video, as the main list shows it.
struct LibraryVideo: Identifiable {
    /// The video's URL — stable across a re-download, unlike the database row.
    var id: String { url }

    var recordID: Int64?
    var url: String
    /// The Slack message this came from, empty for a manually added video.
    var channel = ""
    var messageTS = ""

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

        // Newest row wins when a URL has been downloaded more than once. Playlists
        // are skipped — a playlist is a container whose members each have a row of
        // their own, so it is not a video file and gets no line in the list.
        var byURL: [String: LibraryVideo] = [:]
        var order: [String] = []
        for entry in entries
        where byURL[entry.url] == nil && !YouTubeLink.isPlaylist(entry.url) {
            let file = Self.fileInfo(entry.filePath)
            byURL[entry.url] = LibraryVideo(
                recordID: entry.id,
                url: entry.url,
                channel: entry.channel,
                messageTS: entry.messageTS,
                filePath: entry.filePath,
                status: entry.status,
                viewCount: entry.viewCount,
                lastViewedAt: entry.lastViewedAt,
                download: active.first { $0.videoURL == entry.url },
                fileExists: file.exists,
                posterPath: Self.poster(for: entry.filePath),
                downloadedAt: file.modified ?? entry.updatedAt,
                sizeBytes: file.size ?? entry.sizeBytes,
                tags: entry.tags)
            order.append(entry.url)
        }

        // Anything queued in the last instant has no row yet.
        for download in active where byURL[download.videoURL] == nil {
            byURL[download.videoURL] = LibraryVideo(
                recordID: download.recordID,
                url: download.videoURL,
                filePath: download.destination?.path,
                status: .downloading,
                download: download,
                fileExists: Self.fileInfo(download.destination?.path).exists,
                posterPath: Self.poster(for: download.destination?.path),
                downloadedAt: Date(),
                sizeBytes: Self.fileInfo(download.destination?.path).size)
            order.insert(download.videoURL, at: 0)
        }

        // Whatever is downloading stays pinned at the top — it's the thing
        // happening right now — and everything else sorts by how it's been used.
        let all = order.compactMap { byURL[$0] }.sorted(by: Self.isOrderedBefore)
        videos = all.filter(\.isDownloading) + all.filter { !$0.isDownloading }
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
