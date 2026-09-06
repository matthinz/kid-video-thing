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

    /// Renames a video's folder and file to `<name> [<id>].<ext>`, leaving the
    /// poster and the video ID alone.
    ///
    /// The ID suffix is kept because everything that finds this file again looks
    /// for it — `locate(videoID:in:)`, and Plex, which matches its own items back
    /// to our rows by the ID in the path. The layout stays one-folder-per-video;
    /// `isOrganized` requires the folder and file names to agree.
    ///
    /// **The order here is for Plex's benefit.** The new folder is built up rather
    /// than the old one renamed: poster first, then the video, then anything else
    /// left over, and only then is the old folder removed. Plex watches the
    /// library directory and rescans what changes, so it can look at a
    /// half-finished rename — and what it must never catch is a video file with no
    /// artwork beside it, because it will index the item without a poster and keep
    /// that answer. Putting `poster.jpg` in place before the video appears means
    /// the folder is never observably a video without its cover.
    ///
    /// Renaming the folder instead has the same problem one level up: the whole
    /// subtree disappears and reappears under a new name, and the intermediate
    /// step needed to get the file's own name right leaves the folder briefly
    /// holding a video that doesn't match it.
    ///
    /// Returns the video's new location. A rename onto a name already in use is
    /// left alone rather than clobbering it.
    @discardableResult
    static func rename(_ videoFile: URL, to newName: String) throws -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: videoFile.path) else { return videoFile }

        let organized = try organize(videoFile)
        let id = videoID(of: organized)
        let base = sanitize(newName)
        guard !base.isEmpty else { return organized }

        let folderName = id.map { "\(base) [\($0)]" } ?? base
        guard folderName != organized.deletingPathExtension().lastPathComponent else {
            return organized
        }

        let root = organized.deletingLastPathComponent().deletingLastPathComponent()
        let newFolder = root.appending(path: folderName, directoryHint: .isDirectory)
        let newFile = newFolder.appending(
            path: folderName + "." + organized.pathExtension)

        guard !manager.fileExists(atPath: newFolder.path) else { return organized }

        let oldFolder = organized.deletingLastPathComponent()
        try manager.createDirectory(at: newFolder, withIntermediateDirectories: true)

        // Poster first, so the video is never sitting in a folder without it.
        let oldPoster = oldFolder.appending(path: posterName)
        var posterMoved = false
        if manager.fileExists(atPath: oldPoster.path) {
            try manager.moveItem(at: oldPoster, to: newFolder.appending(path: posterName))
            posterMoved = true
        }

        // Then the video. If this fails the poster goes back where it was and the
        // empty new folder is cleared away, so a failed rename changes nothing.
        do {
            try manager.moveItem(at: organized, to: newFile)
        } catch {
            if posterMoved {
                try? manager.moveItem(at: newFolder.appending(path: posterName), to: oldPoster)
            }
            try? manager.removeItem(at: newFolder)
            throw error
        }

        // Then everything else the folder was holding — subtitles, .nfo, whatever
        // yt-dlp left behind. These are extras: failing to bring one across isn't
        // worth undoing a rename that has otherwise worked.
        for leftover in contents(of: oldFolder) {
            try? manager.moveItem(
                at: leftover, to: newFolder.appending(path: leftover.lastPathComponent))
        }
        try? manager.removeItem(at: oldFolder)

        return newFile
    }

    /// The YouTube ID in a file's name, if it carries one.
    static func videoID(of videoFile: URL) -> String? {
        let name = videoFile.deletingPathExtension().lastPathComponent
        guard name.hasSuffix("]"), let open = name.range(of: "[", options: .backwards) else {
            return nil
        }
        let id = String(name[open.upperBound..<name.index(before: name.endIndex)])
        return YTDLP.isVideoID(id) ? id : nil
    }

    /// A video file's own name with the ` [<id>]` suffix taken off — what the
    /// title was before the ID was appended, and what a rename works from.
    static func baseName(of videoFile: URL) -> String {
        let name = videoFile.deletingPathExtension().lastPathComponent
        guard videoID(of: videoFile) != nil,
            let bracket = name.range(of: " [", options: .backwards)
        else { return name }
        return String(name[name.startIndex..<bracket.lowerBound])
    }

    /// A title, made safe to use as a folder name.
    ///
    /// `/` and `:` are the two characters macOS won't take, and square brackets go
    /// too — a stray `[…]` at the end would be mistaken for the video ID suffix.
    static func sanitize(_ title: String) -> String {
        var cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\[]"))
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        // A leading dot would hide the folder; the cap keeps the whole path well
        // inside the 255-byte limit once the ID and extension are added.
        if cleaned.count > 120 {
            cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces)
        }
        return cleaned
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
