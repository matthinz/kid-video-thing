//
//  PlaylistSync.swift
//  kid-video-thing
//

import Foundation
import Observation

/// Turns emoji reactions in Slack into Plex playlist membership.
///
/// A playlist called "Dinosaurs 🦕" is claimed by the 🦕 reaction: putting it on a
/// message adds that message's videos to the playlist, taking it off removes
/// them. Playlists are matched on the emoji in their title, so naming one is the
/// whole of the setup — nothing here needs configuring.
///
/// A message holding a playlist link covers all of its videos at once, which is
/// what makes "react once, file twenty-three episodes" work.
@MainActor
@Observable
final class PlaylistSync {
    private(set) var activity: [String] = []

    /// Reactions the app uses for its own bookkeeping. They never mean "file this
    /// somewhere", so a playlist can't claim them.
    private static let reserved: Set<String> = [
        SlackClient.Reaction.seen.rawValue,
        SlackClient.Reaction.done.rawValue,
        SlackClient.Reaction.failed.rawValue,
        SlackClient.Reaction.deleted.rawValue,
    ]

    private let settings: AppSettings
    private let store: VideoStore
    private let library: Library

    init(settings: AppSettings, store: VideoStore, library: Library) {
        self.settings = settings
        self.store = store
        self.library = library
    }

    private var client: PlexClient {
        let token =
            settings.plexToken.isEmpty
            ? (PlexClient.discoverToken() ?? "")
            : settings.plexToken
        return PlexClient(token: token)
    }

    /// Applies one reaction change to Plex.
    ///
    /// This is the Slack-to-Plex direction. The other way round — Plex membership
    /// deciding what the message should show — is PlexSync's job, and the tags
    /// written here are only to keep the row honest until the next sync confirms
    /// them.
    func apply(reaction name: String, added: Bool, channel: String, timestamp: String) async {
        guard !Self.reserved.contains(name) else { return }
        guard let emoji = EmojiNames.character(for: name) else {
            note("Ignoring :\(name): — not an emoji we can match to a playlist.")
            return
        }

        let videos = await store.entries(channel: channel, messageTS: timestamp)
            .filter { $0.status != .deleted }
        guard !videos.isEmpty else {
            note("\(emoji) on a message with no videos of ours — nothing to file.")
            return
        }

        let client = self.client
        do {
            let matching = try await client.playlists().filter { $0.emoji.contains(emoji) }
            guard !matching.isEmpty else {
                note("No Plex playlist has \(emoji) in its name — nothing to do.")
                return
            }

            // Plex is keyed by its own ratingKey, so the videos have to be looked
            // up by the YouTube ID in their filenames.
            var ratingKeys: [String: String] = [:]
            for item in try await client.allItems() {
                if let id = item.youTubeID { ratingKeys[id] = item.ratingKey }
            }

            var affected: [(entry: VideoStore.Entry, ratingKey: String)] = []
            for video in videos {
                guard let id = CoverArt.videoID(from: video.url), let key = ratingKeys[id] else {
                    continue
                }
                affected.append((video, key))
            }
            guard !affected.isEmpty else {
                note("\(emoji): Plex doesn't know these videos yet — scan the library first.")
                return
            }

            for playlist in matching {
                let existing = try await client.playlistItems(playlist.ratingKey)
                if added {
                    // Plex will happily hold the same video twice, so check first.
                    let present = Set(existing.map(\.ratingKey))
                    let toAdd = affected.filter { !present.contains($0.ratingKey) }
                    for item in toAdd {
                        try await client.addToPlaylist(
                            playlist.ratingKey, ratingKey: item.ratingKey)
                    }
                    note("\(emoji) added \(toAdd.count) video(s) to \(playlist.title).")
                } else {
                    let doomed = Set(affected.map(\.ratingKey))
                    let toRemove = existing.filter { doomed.contains($0.ratingKey) }
                    for item in toRemove {
                        try await client.removeFromPlaylist(
                            playlist.ratingKey, itemID: item.playlistItemID)
                    }
                    note("\(emoji) removed \(toRemove.count) video(s) from \(playlist.title).")
                }
            }

            for (entry, _) in affected {
                var tags = Set(entry.tags)
                if added { tags.insert(emoji) } else { tags.remove(emoji) }
                await store.setTags(id: entry.id, tags: Array(tags))
            }
            await library.refresh()
        } catch {
            note("\(emoji) failed: \(error.localizedDescription)")
        }
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("[playlist] \(message)\n".utf8))
        activity.insert(message, at: 0)
        if activity.count > 30 { activity.removeLast(activity.count - 30) }
    }
}
