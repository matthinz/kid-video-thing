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
    /// to our rows by the ID in the path. The folder and the file are renamed
    /// together so the layout stays one-folder-per-video; `isOrganized` requires
    /// the two names to agree.
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

        // The file moves first, while its folder still has the old name: renaming
        // the folder first would leave the file's own name stale if this threw.
        let staged = organized.deletingLastPathComponent().appending(
            path: newFile.lastPathComponent)
        try manager.moveItem(at: organized, to: staged)
        do {
            try manager.moveItem(at: staged.deletingLastPathComponent(), to: newFolder)
        } catch {
            try? manager.moveItem(at: staged, to: organized)
            throw error
        }
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
