//
//  LibraryPruner.swift
//  kid-video-thing
//

import Foundation
import Observation

/// Keeps the library under its disk limit by dropping the least interesting
/// videos.
///
/// "Least interesting" is the bottom of the main list, reversed: videos nobody
/// has watched go before any video that has been played, and within each group
/// the oldest goes first. That ordering is deliberately the same one on screen,
/// so what gets deleted is always what you can see sitting at the bottom.
@MainActor
@Observable
final class LibraryPruner {
    private(set) var totalBytes: Int64 = 0
    private(set) var lastPrunedAt: Date?
    private(set) var lastEvictedCount = 0
    private(set) var activity: [String] = []
    private(set) var isPruning = false

    private let settings: AppSettings
    private let store: VideoStore
    private let library: Library

    init(settings: AppSettings, store: VideoStore, library: Library) {
        self.settings = settings
        self.store = store
        self.library = library
    }

    private var client: SlackClient {
        SlackClient(botToken: settings.slackBotToken, appToken: settings.slackAppToken)
    }

    /// Recomputes what the library is using, without deleting anything.
    func measure() {
        totalBytes = library.videos.compactMap(\.sizeBytes).reduce(0, +)
    }

    /// Runs a prune on demand, rather than waiting for a download to trigger one.
    func pruneNow() {
        Task { await pruneIfNeeded(explainWhenUnderLimit: true) }
    }

    /// Deletes from the bottom of the list until the library fits.
    ///
    /// `keeping` is the video that just finished downloading: evicting it would
    /// mean downloading something and watching it vanish, which is never what
    /// anyone wants — even when it alone busts the limit.
    ///
    /// `explainWhenUnderLimit` says so in the log when there's nothing to do,
    /// which a button press deserves and an automatic run would only clutter.
    func pruneIfNeeded(
        keeping keepURL: String? = nil, explainWhenUnderLimit: Bool = false
    ) async {
        guard !isPruning else { return }
        isPruning = true
        defer { isPruning = false }

        await library.refresh()
        measure()

        let limit = settings.maxDiskUsageBytes
        guard totalBytes > limit else {
            if explainWhenUnderLimit {
                note("Using \(format(totalBytes)) of \(format(limit)) — nothing to delete.")
                lastPrunedAt = Date()
                lastEvictedCount = 0
            }
            return
        }

        note(
            "Library is \(format(totalBytes)), over the \(format(limit)) limit — freeing space.")

        var remaining = totalBytes
        var evicted: [LibraryVideo] = []

        for video in library.videos.reversed() {
            guard remaining > limit else { break }
            // Only whole, settled files are candidates.
            guard !video.isDownloading, video.fileExists, let file = video.file else { continue }
            guard video.url != keepURL else { continue }

            do {
                try MediaLayout.remove(file)
            } catch {
                note("Couldn't delete \(video.title): \(error.localizedDescription)")
                continue
            }
            // Every row for this video, not just one — the same file can be
            // recorded against more than one message.
            for recordID in video.recordIDs {
                await store.finish(id: recordID, status: .deleted, filePath: nil)
            }
            remaining -= video.sizeBytes ?? 0
            evicted.append(video)
            note("Deleted \(video.title) (\(format(video.sizeBytes ?? 0)))")
        }

        await markDeleted(evicted)

        if remaining > limit {
            note(
                "Still \(format(remaining)) after deleting everything eligible — "
                    + "raise the limit or remove videos by hand.")
        }

        lastEvictedCount = evicted.count
        lastPrunedAt = Date()
        await library.refresh()
        measure()
    }

    /// Puts ❌ on the Slack messages whose videos have gone.
    ///
    /// A message only gets marked once nothing of it survives — a playlist can
    /// lose one episode and still have twenty-two on disk, and claiming the whole
    /// message was deleted would be wrong. It would also be undone: a re-sync
    /// swaps our ❌ back for ✅ as soon as it finds a file still there.
    private func markDeleted(_ evicted: [LibraryVideo]) async {
        let messages = Set(
            evicted
                .flatMap(\.messages)
                .filter { !$0.channel.isEmpty && !$0.timestamp.isEmpty })
        guard !messages.isEmpty, !settings.slackBotToken.isEmpty else { return }

        let client = self.client
        for message in messages {
            let survivors = await store.entries(
                channel: message.channel, messageTS: message.timestamp)
                .filter { $0.status != .deleted }
            guard survivors.isEmpty else {
                note("Left \(message.timestamp) unmarked — it still has videos on disk.")
                continue
            }
            try? await client.removeReaction(
                .done, channel: message.channel, timestamp: message.timestamp)
            try? await client.addReaction(
                .deleted, channel: message.channel, timestamp: message.timestamp)
        }
    }

    private func format(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("[disk] \(message)\n".utf8))
        activity.insert(message, at: 0)
        if activity.count > 30 { activity.removeLast(activity.count - 30) }
    }
}
