//
//  YTDLP.swift
//  kid-video-thing
//

import Foundation

enum YTDLPError: LocalizedError {
    case notFound
    case failed(exitCode: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            return """
                Couldn't find yt-dlp. Install it (for example, `brew install yt-dlp`) \
                or set the full path to it in Settings.
                """
        case .failed(let exitCode, let output):
            let tail = output.split(separator: "\n").suffix(3).joined(separator: "\n")
            return "yt-dlp exited with code \(exitCode).\n\(tail)"
        }
    }
}

/// Locates and runs the yt-dlp binary.
enum YTDLP {
    /// Places Homebrew and friends tend to put yt-dlp. The app doesn't inherit a
    /// login shell's PATH, so we look explicitly.
    static let searchPaths = [
        "/opt/homebrew/bin/yt-dlp",
        "/usr/local/bin/yt-dlp",
        "/opt/local/bin/yt-dlp",
        "/usr/bin/yt-dlp",
    ]

    /// Resolves the binary to use, preferring an explicit override from Settings.
    static func resolveExecutable(override: String) -> URL? {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let url = URL(filePath: trimmed)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }
        return nil
    }

    /// Directories yt-dlp needs on PATH to find its helpers — ffmpeg for merging
    /// formats, and a JS runtime (deno) for YouTube's challenges.
    nonisolated static let toolDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin",
        "/bin",
    ]

    /// A launched-from-Finder app inherits a bare PATH, so build one explicitly.
    /// Real binaries go first: version-manager shims (asdf, mise) often shadow a
    /// working install with one that reports no version, which yt-dlp rejects.
    nonisolated static func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let inherited = environment["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        let combined = toolDirectories + inherited.filter { !toolDirectories.contains($0) }
        environment["PATH"] = combined.joined(separator: ":")
        return environment
    }

    /// Lists the video IDs in a playlist, newest contents each time it's called.
    /// Nothing is downloaded — `--flat-playlist` just reads the index.
    nonisolated static func playlistVideoIDs(
        url: String, executable: URL
    ) async throws -> [String] {
        let environment = childEnvironment()
        return try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "--flat-playlist",
                "--yes-playlist",
                "--ignore-errors",
                "--no-warnings",
                "--print", "%(id)s",
                url,
            ]
            process.environment = environment

            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()

            let data = output.fileHandleForReading.readDataToEndOfFile()
            let problems = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let ids = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter(isVideoID)

            // `--ignore-errors` can exit non-zero over a single private video while
            // still listing everything else, so a non-empty result wins.
            guard !ids.isEmpty else {
                if process.terminationStatus != 0 {
                    throw YTDLPError.failed(
                        exitCode: process.terminationStatus,
                        output: String(decoding: problems, as: UTF8.self))
                }
                return []
            }
            return ids
        }.value
    }

    /// YouTube IDs are 11 characters of URL-safe base64.
    nonisolated static func isVideoID(_ candidate: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "-_").union(.alphanumerics)
        return candidate.count == 11 && candidate.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Runs yt-dlp for `url`, writing into `directory`.
    ///
    /// `onOutput` is called on the main actor for each line yt-dlp emits (stdout and
    /// stderr, interleaved). Throws on a non-zero exit or cancellation.
    static func download(
        videoURL: String,
        into directory: URL,
        executable: URL,
        onOutput: @escaping @MainActor (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.arguments = [
            "--newline",
            "--no-playlist",
            "--restrict-filenames",
            "--paths", directory.path,
            // Each video gets its own folder so a Plex `poster.jpg` applies to it
            // alone; yt-dlp creates the intermediate directory itself.
            "--output", "%(title)s [%(id)s]/%(title)s [%(id)s].%(ext)s",
            videoURL,
        ]
        process.environment = childEnvironment()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var transcript = ""
        let collected = LineCollector { line in
            transcript += line + "\n"
            Task { @MainActor in onOutput(line) }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collected.append(data)
            }
        }

        try process.run()

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in continuation.resume() }
            }
            // Drain anything still buffered after exit.
            if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                collected.append(rest)
            }
            collected.flush()
        } onCancel: {
            process.terminate()
        }

        try Task.checkCancellation()

        guard process.terminationStatus == 0 else {
            throw YTDLPError.failed(exitCode: process.terminationStatus, output: transcript)
        }
    }
}

/// Splits a stream of bytes into whole lines. yt-dlp also uses \r for progress
/// updates, so both separators end a line.
private nonisolated final class LineCollector: @unchecked Sendable {
    private var buffer = ""
    private let emit: (String) -> Void
    private let lock = NSLock()

    init(emit: @escaping (String) -> Void) {
        self.emit = emit
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer += String(decoding: data, as: UTF8.self)
        while let index = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[buffer.startIndex..<index])
            buffer = String(buffer[buffer.index(after: index)...])
            if !line.isEmpty { emit(line) }
        }
    }

    func flush() {
        lock.lock()
        defer { lock.unlock() }
        let line = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if !line.isEmpty { emit(line) }
    }
}
