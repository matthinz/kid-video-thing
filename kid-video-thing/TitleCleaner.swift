//
//  TitleCleaner.swift
//  kid-video-thing
//

import Foundation
import Observation

/// Turns the title yt-dlp gave a video into something a six-year-old can read on
/// a shelf in Plex.
///
/// YouTube titles are written for the algorithm, not for anyone browsing:
/// "Pizza Bean Mr Bean Cartoon Season 2 Full Episodes Mr Bean Official" is the
/// "Pizza Bean" episode with the search terms bolted on. Claude strips that back,
/// and the video's folder is renamed on disk — a database-only title would look
/// right in the menu bar and wrong on the television, which is the screen that
/// matters.
///
/// The file on disk is never touched. Renaming it worked, but it moved the video
/// out from under Plex, which then had to work out what it was looking at all
/// over again. The title lives in our own database instead and is pushed to Plex
/// directly — and pinned there, because an unlocked title is one Plex will
/// happily re-derive from the filename at the next refresh.
///
/// That leaves the filename as the thing nobody edits, which makes it a reliable
/// place to start from: every cleanup works from the name yt-dlp chose, so
/// guesswork never compounds and undo always has somewhere to land.
///
/// Playlist membership is context, not decoration: someone browsing the
/// "Mr Bean Cartoon" playlist already knows it's Mr Bean, so the show name comes
/// out of the title while the video sits there.
@MainActor
@Observable
final class TitleCleaner {
    private(set) var activity: [String] = []
    /// Video IDs with a rename in flight, so a row can show progress and refuse
    /// to start a second one.
    private(set) var working: Set<String> = []

    private let settings: AppSettings
    private let store: VideoStore
    private let library: Library

    init(settings: AppSettings, store: VideoStore, library: Library) {
        self.settings = settings
        self.store = store
        self.library = library
    }

    /// Whether there's an API key to call with. Everything here is a no-op
    /// without one — a missing key means the feature is off, not broken.
    var isConfigured: Bool {
        !settings.claudeAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func isWorking(_ video: LibraryVideo) -> Bool { working.contains(video.id) }

    // MARK: - Entry points

    /// Cleans a title the moment a video lands, if the feature is switched on.
    /// A fresh download is in no playlist yet, so there's no context to use.
    func cleanNewDownload(_ download: Download) async {
        guard settings.cleanTitlesOnDownload, isConfigured else { return }
        guard let path = download.destination?.path else { return }
        await library.refresh()
        guard let video = library.videos.first(where: { $0.filePath == path })
        else { return }
        await clean(video, thenPush: true)
    }

    /// The "Magic Rename" button: clean this one video and tell Plex.
    func clean(_ video: LibraryVideo) async {
        await clean(video, thenPush: true)
    }

    /// `thenPush` is false when the caller is working through several videos and
    /// will push once at the end — a push re-reads every Plex library section, so
    /// doing it per video would make a playlist change quadratic for no gain.
    private func clean(_ video: LibraryVideo, thenPush: Bool) async {
        guard isConfigured else {
            note("No Claude API key — add one in Settings → Claude.")
            return
        }
        guard !working.contains(video.id) else { return }
        working.insert(video.id)
        defer { working.remove(video.id) }

        // Always start from what yt-dlp called it, never from a title we already
        // produced: cleaning a cleaned title compounds the guesswork and throws
        // away information a later playlist change might need.
        let original = video.originalTitle
        let playlists = await playlistNames(for: video)
        let context = playlists.sorted().joined(separator: ", ")

        do {
            let title: String
            if let cached = await store.cachedTitle(videoID: video.id, context: context) {
                title = cached
            } else {
                title = try await ask(original: original, playlists: playlists)
                await store.cacheTitle(videoID: video.id, context: context, title: title)
            }
            for id in video.recordIDs {
                await store.setTitle(id: id, title: title, context: context)
            }
            await library.refresh()
            note(describe(original: original, now: title, playlists: playlists))
        } catch {
            note("\(video.title): \(error.localizedDescription)")
            return
        }

        // Best effort: Plex may not have scanned this video yet, in which case
        // there is nothing to write to and the next sync will catch it.
        if thenPush { await pushToPlex() }
    }

    /// Drops a cleaned title, going back to whatever the filename says.
    ///
    /// Plex is handed the field back rather than pinned to the old title: an
    /// unlocked title is one Plex derives from the filename itself, which is
    /// exactly where undo wants to end up.
    func undo(_ video: LibraryVideo) async {
        guard video.isCleaned else { return }
        guard !working.contains(video.id) else { return }
        working.insert(video.id)
        defer { working.remove(video.id) }

        let original = video.originalTitle
        for id in video.recordIDs {
            await store.clearTitle(id: id)
        }
        await library.refresh()

        if let client = plexClient, let item = await plexItem(for: video.id, using: client) {
            do {
                try await client.setTitle(
                    item.ratingKey, inSection: item.sectionKey, title: original, locked: false)
            } catch {
                note("Couldn't hand \"\(original)\" back to Plex: \(error.localizedDescription)")
            }
        }
        note("Put back: \(original)")
    }

    /// Re-runs cleanup for every video on a Slack message whose playlist
    /// membership just changed.
    ///
    /// Adding and removing both come through here: the title is always rebuilt
    /// from the original against whatever playlists the video is in *now*, so
    /// taking the last reaction off lands back exactly where it started. The
    /// cache means going back to a context already seen costs nothing.
    func playlistsChanged(channel: String, timestamp: String) async {
        guard settings.cleanTitlesOnDownload, isConfigured else { return }
        await library.refresh()
        let message = SlackMessage(channel: channel, timestamp: timestamp)
        for video in library.videos where video.messages.contains(message) {
            guard video.status == .done else { continue }
            await clean(video, thenPush: false)
        }
        await pushToPlex()
    }

    // MARK: - The call

    private static let systemPrompt = """
        You clean up YouTube video titles so they read well on a shelf of \
        children's videos in Plex. You reply with the cleaned title and nothing \
        else — no quotes, no explanation, no trailing punctuation.

        Cut the parts that are there for search ranking rather than for a reader: \
        channel names, "Full Episode(s)", "Official", season and episode counts, \
        durations, upload years, ALL CAPS, emoji, exclamation marks, and hashtags. \
        Keep what identifies this particular video — usually the episode or story \
        name. Use Title Case.

        Keep the real title's wording. Do not invent a description, translate it, \
        or make one up when the original is thin. If there is nothing to cut, \
        repeat the title back tidied up. If all that is left would be generic \
        ("Episode 4"), keep enough of the original to tell it apart from its \
        neighbours.
        """

    private func ask(original: String, playlists: [String]) async throws -> String {
        let readable = original.replacingOccurrences(of: "_", with: " ")
        var prompt = "Title: \(readable)"
        if !playlists.isEmpty {
            prompt += """


                This video sits in the Plex playlist\(playlists.count == 1 ? "" : "s") \
                \(playlists.map { "\"\($0)\"" }.joined(separator: ", ")). Whoever is \
                browsing can already see the playlist name, so drop anything the \
                title repeats from it — but never cut so much that the video stops \
                being identifiable on its own.
                """
        }

        let client = ClaudeClient(apiKey: settings.claudeAPIKey, model: settings.claudeModel)
        let reply = try await client.complete(system: Self.systemPrompt, prompt: prompt)

        // Take the first line only: a stray sentence of preamble is easier to
        // survive than to prevent.
        let title =
            reply
            .split(separator: "\n")
            .first
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            ?? ""
        guard !Self.normalize(title).isEmpty else {
            throw ClaudeError.badResponse("no usable title in \"\(reply.prefix(80))\"")
        }
        return Self.normalize(title)
    }

    /// Collapses whitespace and caps the length. Nothing here is about the
    /// filesystem any more — the title only has to be sane to read and to store.
    private static func normalize(_ title: String) -> String {
        let collapsed = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count > 200
            ? String(collapsed.prefix(200)).trimmingCharacters(in: .whitespaces)
            : collapsed
    }

    // MARK: - Telling Plex

    private var plexClient: PlexClient? {
        let token =
            settings.plexToken.isEmpty
            ? (PlexClient.discoverToken() ?? "")
            : settings.plexToken
        return token.isEmpty ? nil : PlexClient(token: token)
    }

    private func plexItem(for videoID: String, using client: PlexClient) async
        -> PlexClient.Item?
    {
        guard let items = try? await client.allItems() else { return nil }
        return items.first { $0.youTubeID == videoID }
    }

    /// Brings Plex into line with the titles and posters we hold.
    ///
    /// Both halves are pinned once set, because Plex treats an unlocked title and
    /// an unlocked poster as its own business: it re-derives the title from the
    /// filename and re-picks the artwork whenever it refreshes an item, which is
    /// how a library ends up showing video stills instead of the posters sitting
    /// right beside the files.
    ///
    /// Safe to call whenever. Titles are compared against what Plex currently
    /// shows, so a video already in step costs nothing; posters are asked about
    /// only once per video, since whether a field is locked can't be read back
    /// from the bulk listing and checking each one every sync would mean a
    /// request per video, forever.
    func pushToPlex() async {
        guard let client = plexClient else { return }

        let items: [PlexClient.Item]
        do {
            items = try await client.allItems()
        } catch {
            note("Couldn't reach Plex to update titles: \(error.localizedDescription)")
            return
        }

        var byID: [String: PlexClient.Item] = [:]
        for item in items {
            if let id = item.youTubeID { byID[id] = item }
        }

        // Rows are per Slack message; several can share one video and one file.
        // Group them so Plex is told once and every row learns the outcome.
        var rowsForVideo: [String: [VideoStore.Entry]] = [:]
        for entry in await store.allEntries() {
            guard let id = CoverArt.videoID(from: entry.url) else { continue }
            rowsForVideo[id, default: []].append(entry)
        }

        var titlesPushed = 0
        var postersPinned = 0

        for (videoID, rows) in rowsForVideo {
            guard let item = byID[videoID] else { continue }

            if let wanted = rows.compactMap(\.title).first, item.title != wanted {
                do {
                    try await client.setTitle(
                        item.ratingKey, inSection: item.sectionKey, title: wanted, locked: true)
                    titlesPushed += 1
                } catch {
                    note("Couldn't set \"\(wanted)\" in Plex: \(error.localizedDescription)")
                }
            }

            if rows.contains(where: { !$0.plexPosterLocked }) {
                if await pinPoster(item, using: client) {
                    for row in rows { await store.setPlexPosterLocked(id: row.id, true) }
                    postersPinned += 1
                }
            }
        }

        if titlesPushed > 0 || postersPinned > 0 {
            note(
                "Plex updated: \(titlesPushed) title(s), \(postersPinned) poster(s) pinned.")
            await library.refresh()
        }
    }

    /// Points Plex at a video's own `poster.jpg` and pins it there.
    ///
    /// Returns false when there's nothing to do or the attempt failed, so the
    /// video stays on the list to try again next time.
    private func pinPoster(_ item: PlexClient.Item, using client: PlexClient) async -> Bool {
        do {
            let posters = try await client.posters(item.ratingKey)
            guard let local = posters.first(where: \.isLocal) else { return false }
            if !local.selected {
                try await client.selectPoster(item.ratingKey, url: local.url)
            }
            try await client.lockThumb(item.ratingKey, inSection: item.sectionKey)
            return true
        } catch {
            note("Couldn't pin a poster in Plex: \(error.localizedDescription)")
            return false
        }
    }

    /// The Plex playlists this video is in, by name.
    ///
    /// The row carries emoji, because that's what Slack gives us; the names are
    /// what's useful as context, so they're looked up from Plex. Plex being
    /// unreachable just means cleaning without context, not failing.
    private func playlistNames(for video: LibraryVideo) async -> [String] {
        guard !video.tags.isEmpty else { return [] }
        let token =
            settings.plexToken.isEmpty
            ? (PlexClient.discoverToken() ?? "")
            : settings.plexToken
        guard !token.isEmpty else { return [] }

        do {
            let playlists = try await PlexClient(token: token).playlists()
            return playlists
                .filter { playlist in video.tags.contains { playlist.emoji.contains($0) } }
                .map(\.title)
        } catch {
            note("Couldn't read Plex playlists for context — cleaning without them.")
            return []
        }
    }

    private func describe(original: String, now: String, playlists: [String]) -> String {
        let was = original.replacingOccurrences(of: "_", with: " ")
        let context = playlists.isEmpty ? "" : " (in \(playlists.joined(separator: ", ")))"
        return "\(was) → \(now)\(context)"
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("[titles] \(message)\n".utf8))
        activity.insert(message, at: 0)
        if activity.count > 30 { activity.removeLast(activity.count - 30) }
    }
}
