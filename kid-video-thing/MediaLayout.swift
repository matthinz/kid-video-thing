//
//  MediaLayout.swift
//  kid-video-thing
//

import Foundation

/// How videos are arranged on disk.
///
/// Each video lives in its own folder named after it, with its poster alongside
/// as `poster.jpg`:
///
///     Kid Video Thing/
///       Some Show [abc123XYZ_9]/
///         Some Show [abc123XYZ_9].webm
///         poster.jpg
///
/// Plex treats a folder as a single movie, so `poster.jpg` applies to exactly one
/// video — unlike a flat directory, where a folder-level poster would claim every
/// file in it. Videos downloaded before this layout existed sit loose in the root
/// and get moved in as they're found.
nonisolated enum MediaLayout {
    /// Extensions that are never the video itself.
    static let nonVideoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "part", "ytdl", "nfo", "srt", "vtt", "webp", "description",
    ]

    static let posterName = "poster.jpg"

    /// True when the file already sits in a folder named after it.
    static func isOrganized(_ videoFile: URL) -> Bool {
        videoFile.deletingLastPathComponent().lastPathComponent
            == videoFile.deletingPathExtension().lastPathComponent
    }

    /// The folder a video belongs in, whether or not it's there yet.
    static func folder(for videoFile: URL) -> URL {
        isOrganized(videoFile)
            ? videoFile.deletingLastPathComponent()
            : videoFile.deletingPathExtension()
    }

    /// Where the poster for a video belongs.
    static func posterURL(for videoFile: URL) -> URL {
        folder(for: videoFile).appending(path: posterName)
    }

    /// Moves a loose video into its own folder, bringing any old-style
    /// `<name>.jpg` poster with it as `poster.jpg`. Returns the video's location
    /// afterwards — unchanged if it was already organized or isn't there.
    @discardableResult
    static func organize(_ videoFile: URL) throws -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: videoFile.path), !isOrganized(videoFile) else {
            return videoFile
        }

        let folder = videoFile.deletingPathExtension()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        let moved = folder.appending(path: videoFile.lastPathComponent)
        guard !manager.fileExists(atPath: moved.path) else { return moved }
        try manager.moveItem(at: videoFile, to: moved)

        // The old layout put the poster next to the video as `<name>.jpg`.
        let oldPoster = videoFile.deletingPathExtension().appendingPathExtension("jpg")
        let newPoster = folder.appending(path: posterName)
        if manager.fileExists(atPath: oldPoster.path), !manager.fileExists(atPath: newPoster.path) {
            try? manager.moveItem(at: oldPoster, to: newPoster)
        }
        return moved
    }

    /// Removes a video and everything that belongs to it — the whole folder once
    /// it's organized, or the loose file and its old-style poster if not.
    static func remove(_ videoFile: URL) throws {
        let manager = FileManager.default
        if isOrganized(videoFile) {
            try manager.removeItem(at: videoFile.deletingLastPathComponent())
        } else {
            try manager.removeItem(at: videoFile)
            try? manager.removeItem(
                at: videoFile.deletingPathExtension().appendingPathExtension("jpg"))
        }
    }

    /// Finds a video by its YouTube ID, in either layout. yt-dlp's output template
    /// ends in `[<id>].<ext>`, so the ID identifies the file even when yt-dlp never
    /// named it in its output. Newest match wins.
    static func locate(videoID: String, in root: URL) -> URL? {
        var candidates = videos(in: root, matching: videoID)
        for subfolder in subfolders(of: root) {
            candidates += videos(in: subfolder, matching: videoID)
        }
        return
            candidates
            .max { modified($0) < modified($1) }
    }

    // MARK: - Directory scanning

    private static func subfolders(of directory: URL) -> [URL] {
        contents(of: directory).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private static func videos(in directory: URL, matching videoID: String) -> [URL] {
        contents(of: directory).filter { url in
            !nonVideoExtensions.contains(url.pathExtension.lowercased())
                && url.deletingPathExtension().lastPathComponent.hasSuffix("[\(videoID)]")
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
        }
    }

    private static func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])) ?? []
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }
}
