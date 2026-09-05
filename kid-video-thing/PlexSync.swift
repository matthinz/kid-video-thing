//
//  PlexSync.swift
//  kid-video-thing
//

import Foundation
import Observation

/// Keeps the library's viewing figures in step with Plex.
///
/// Plex is the authority on two things, and this copies both into our records,
/// matching on the YouTube ID that yt-dlp bakes into every filename:
///
/// - what's been watched — view count and last-viewed date;
/// - which emoji-named playlists a video belongs to, which is what the emoji on
///   each row in the list are showing.
///
/// Nothing is ever written back to Plex, and no reactions are posted to Slack:
/// reactions belong to whoever put them there. Reacting in Slack is what files a
/// video into a playlist — see PlaylistSync — and this only reports the result.
@MainActor
@Observable
final class PlexSync {
    private(set) var isSyncing = false
    /// The last failure, cleared as soon as a sync succeeds.
    private(set) var lastError: String?
    private(set) var lastSyncedAt: Date?
    /// How many videos Plex and our records agreed on, last time round.
    private(set) var matchedCount = 0
    private(set) var activity: [String] = []

    private let settings: AppSettings
    private let store: VideoStore
    private let library: Library
    private var loop: Task<Void, Never>?

    init(settings: AppSettings, store: VideoStore, library: Library) {
        self.settings = settings
        self.store = store
        self.library = library
    }

    var isRunning: Bool { loop != nil }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Picks up a changed interval, which the sleeping loop wouldn't notice.
    func restart() {
        stop()
        start()
    }

    /// Syncs immediately, without waiting for the next tick.
    func syncNow() {
        Task { await sync() }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            await sync()
            try? await Task.sleep(for: .seconds(Double(settings.plexSyncMinutes) * 60))
        }
    }

    private func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let token =
            settings.plexToken.isEmpty
            ? (PlexClient.discoverToken() ?? "")
            : settings.plexToken

        do {
            let items = try await PlexClient(token: token).allItems()

            // Plex can hold the same video in more than one library; the most
            // recently watched copy is the one worth reporting.
            var byID: [String: PlexClient.Item] = [:]
            for item in items {
                guard let id = item.youTubeID else { continue }
                let existing = byID[id]?.lastViewedAt ?? .distantPast
                if item.lastViewedAt ?? .distantPast >= existing { byID[id] = item }
            }

            var matched = 0
            for entry in await store.allEntries() {
                guard let id = CoverArt.videoID(from: entry.url), let item = byID[id] else {
                    continue
                }
                matched += 1

                // Plex omits viewCount instead of sending zero, but having found
                // the video we do know the answer — so an absent count becomes a
                // real 0, distinct from our own nil meaning "never synced".
                let views = item.viewCount ?? 0
                // Only write when something actually moved.
                guard entry.viewCount != views || entry.lastViewedAt != item.lastViewedAt
                else { continue }
                await store.setViewStats(
                    id: entry.id, viewCount: views, lastViewedAt: item.lastViewedAt)
            }

            await syncPlaylistTags(client: PlexClient(token: token))

            matchedCount = matched
            lastSyncedAt = Date()
            lastError = nil
            await library.refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Records which emoji-named playlists hold each video, so the list can show
    /// them. Read-only in both directions: Plex isn't changed, and neither are
    /// the reactions on the Slack message.
    private func syncPlaylistTags(client: PlexClient) async {
        do {
            let playlists = try await client.playlists().filter { !$0.emoji.isEmpty }

            // Plex identifies videos by ratingKey; our records use the URL. The
            // filename's YouTube ID is the bridge between them.
            var idForRatingKey: [String: String] = [:]
            for item in try await client.allItems() {
                if let id = item.youTubeID { idForRatingKey[item.ratingKey] = id }
            }

            var wanted: [String: Set<String>] = [:]  // video id -> emoji
            for playlist in playlists {
                for item in try await client.playlistItems(playlist.ratingKey) {
                    guard let id = idForRatingKey[item.ratingKey] else { continue }
                    wanted[id, default: []].formUnion(playlist.emoji)
                }
            }

            for entry in await store.allEntries() {
                guard let id = CoverArt.videoID(from: entry.url) else { continue }
                let tags = wanted[id] ?? []
                guard tags != Set(entry.tags) else { continue }
                await store.setTags(id: entry.id, tags: Array(tags))
            }
        } catch {
            note("Playlist sync failed: \(error.localizedDescription)")
        }
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("[plex] \(message)\n".utf8))
        activity.insert(message, at: 0)
        if activity.count > 30 { activity.removeLast(activity.count - 30) }
    }
}
