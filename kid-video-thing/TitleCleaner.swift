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
/// Playlist membership is context, not decoration: someone browsing the
/// "Mr Bean Cartoon" playlist already knows it's Mr Bean, so the show name comes
/// out of the title while the video sits there. The name yt-dlp originally chose
/// is kept, so every cleanup starts from the same place and undo always has
/// somewhere to land.
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
        await clean(video)
    }

    /// The "Magic Rename" button, and the re-run after a playlist change.
    func clean(_ video: LibraryVideo) async {
        guard isConfigured else {
            note("No Claude API key — add one in Settings → Claude.")
            return
        }
        guard let file = video.file, video.fileExists else {
            note("\(video.title): no file on disk to rename.")
            return
        }
        guard !working.contains(video.id) else { return }
        working.insert(video.id)
        defer { working.remove(video.id) }

        // Always start from what yt-dlp called it. Cleaning an already-cleaned
        // title compounds the guesswork, and drops information a later playlist
        // change might need.
        let original = video.originalName ?? MediaLayout.baseName(of: file)
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
            try await apply(title, to: video, file: file, original: original, context: context)
            note(describe(original: original, now: title, playlists: playlists))
        } catch {
            note("\(video.title): \(error.localizedDescription)")
        }
    }

    /// Puts a video's original yt-dlp name back on disk.
    func undo(_ video: LibraryVideo) async {
        guard let original = video.originalName else { return }
        guard let file = video.file, video.fileExists else {
            note("\(video.title): no file on disk to rename back.")
            return
        }
        guard !working.contains(video.id) else { return }
        working.insert(video.id)
        defer { working.remove(video.id) }

        do {
            let restored = try MediaLayout.rename(file, to: original)
            for id in video.recordIDs {
                await store.clearRename(id: id, filePath: restored.path)
            }
            await library.refresh()
            note("Put back: \(original)")
        } catch {
            note("\(video.title): \(error.localizedDescription)")
        }
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
            guard video.fileExists else { continue }
            await clean(video)
        }
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
        guard !MediaLayout.sanitize(title).isEmpty else {
            throw ClaudeError.badResponse("no usable title in \"\(reply.prefix(80))\"")
        }
        return title
    }

    /// Renames the file and records where it went, against every row that shares it.
    private func apply(
        _ title: String, to video: LibraryVideo, file: URL, original: String, context: String
    ) async throws {
        let renamed = try MediaLayout.rename(file, to: title)
        for id in video.recordIDs {
            await store.recordRename(
                id: id, filePath: renamed.path, originalName: original, titleContext: context)
        }
        await library.refresh()
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
