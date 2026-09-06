//
//  DownloadManager.swift
//  kid-video-thing
//

import Foundation
import Observation

@Observable
final class Download: Identifiable {
    enum State: Equatable {
        case waiting
        case running
        case finished
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let videoURL: String
    var state: State = .waiting
    /// 0...1 while downloading, nil when yt-dlp hasn't reported progress yet.
    var fraction: Double?
    var statusLine = "Waiting…"
    var log: [String] = []
    /// Last file yt-dlp said it was writing, if we saw one.
    var destination: URL?

    /// Where the download came from, so Slack-sourced items are recognizable.
    enum Origin: Equatable {
        case manual
        case slack(channel: String, timestamp: String)

        var slackMessage: (channel: String, timestamp: String)? {
            guard case .slack(let channel, let timestamp) = self else { return nil }
            return (channel, timestamp)
        }
    }

    var origin: Origin = .manual
    /// The database row this download writes to, once it has one.
    var recordID: Int64?

    private var outcome: Result<Void, Error>?
    private var waiters: [CheckedContinuation<Result<Void, Error>, Never>] = []

    init(videoURL: String) {
        self.videoURL = videoURL
    }

    var isActive: Bool {
        state == .waiting || state == .running
    }

    /// Waits for this download to reach a terminal state.
    func result() async -> Result<Void, Error> {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func finish(_ result: Result<Void, Error>) {
        guard outcome == nil else { return }
        outcome = result
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume(returning: result) }
    }
}

/// Owns the download queue and runs one yt-dlp at a time.
@Observable
final class DownloadManager {
    private(set) var downloads: [Download] = []

    /// Runs after each successful download, before the next one starts — where
    /// the disk limit gets enforced.
    var afterDownload: ((Download) async -> Void)?

    private let settings: AppSettings
    private let store: VideoStore
    private var queue: [Download] = []
    private var currentTask: Task<Void, Never>?

    init(settings: AppSettings, store: VideoStore) {
        self.settings = settings
        self.store = store
    }

    var isBusy: Bool { currentTask != nil }

    /// Queues a URL for download. Returns nil if the input isn't usable.
    ///
    /// `origin` is taken here rather than set afterwards so it's already in place
    /// when the download starts recording itself.
    @discardableResult
    func enqueue(_ rawURL: String, origin: Download.Origin = .manual) -> Download? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeVideoURL(trimmed) else { return nil }

        let download = Download(videoURL: trimmed)
        download.origin = origin
        downloads.insert(download, at: 0)
        queue.append(download)
        startNextIfIdle()
        return download
    }

    func cancel(_ download: Download) {
        if let index = queue.firstIndex(where: { $0 === download }) {
            queue.remove(at: index)
            download.state = .cancelled
            download.statusLine = "Cancelled"
            download.finish(.failure(CancellationError()))
            return
        }
        if download.state == .running {
            currentTask?.cancel()
        }
    }

    /// Every download kicked off by a particular Slack message — more than one
    /// when the message held a playlist.
    func downloads(fromSlackMessage channel: String, timestamp: String) -> [Download] {
        downloads.filter { $0.origin == .slack(channel: channel, timestamp: timestamp) }
    }

    /// Drops a download from the list. Deleting the file itself is the caller's
    /// job — VideoStore is the record of what's on disk.
    func remove(_ download: Download) {
        downloads.removeAll { $0 === download }
    }

    static func looksLikeVideoURL(_ string: String) -> Bool {
        guard !string.isEmpty, let url = URL(string: string), let scheme = url.scheme?.lowercased()
        else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    private func startNextIfIdle() {
        guard currentTask == nil, !queue.isEmpty else { return }
        let download = queue.removeFirst()

        currentTask = Task { [weak self] in
            guard let self else { return }
            await run(download)
            currentTask = nil
            startNextIfIdle()
        }
    }

    private func run(_ download: Download) async {
        download.state = .running
        download.statusLine = "Starting yt-dlp…"

        // Every download gets a row, so the library view shows manually added
        // videos alongside the ones that arrived through Slack.
        let slack = download.origin.slackMessage
        let recordID = await store.startDownload(
            channel: slack?.channel ?? "", messageTS: slack?.timestamp ?? "",
            url: download.videoURL)
        download.recordID = recordID

        do {
            guard let executable = YTDLP.resolveExecutable(override: settings.ytDlpPath) else {
                throw YTDLPError.notFound
            }
            try settings.ensureDownloadDirectoryExists()

            let directory = settings.downloadDirectory

            // yt-dlp decides "have I got this already?" by the filename it would
            // write — `<current YouTube title> [<id>]`. Once a title has been
            // cleaned up, that name no longer matches what's on disk, so yt-dlp
            // would fetch the whole video again into a second folder and the tidy
            // name would be lost. Ask by video ID instead, which is what the rest
            // of the app identifies a video by and what survives a rename.
            if let id = CoverArt.videoID(from: download.videoURL),
                let existing = Self.locateFile(videoID: id, in: directory)
            {
                download.log.append(
                    "[download] \(existing.lastPathComponent) is already here")
                download.destination = existing
            } else {
                try await YTDLP.download(
                    videoURL: download.videoURL,
                    into: directory,
                    executable: executable
                ) { line in
                    download.log.append(line)
                    if download.log.count > 500 {
                        download.log.removeFirst(download.log.count - 500)
                    }
                    Self.apply(line: line, to: download, directory: directory)
                }
            }

            // Belt and braces: yt-dlp's phrasing varies with version and format,
            // and the output template ends in `[<id>]`, so the file can be found.
            if download.destination == nil, let id = CoverArt.videoID(from: download.videoURL) {
                download.destination = Self.locateFile(videoID: id, in: directory)
            }

            // A video downloaded under the old flat layout — or moved in by hand —
            // gets tucked into its own folder before its poster is written.
            if let destination = download.destination {
                download.destination = try? MediaLayout.organize(destination)
            }

            download.fraction = 1
            download.statusLine = "Making cover art…"
            await makeCover(for: download)

            if let recordID {
                await store.finish(
                    id: recordID, status: .done, filePath: download.destination?.path)
            }
            download.state = .finished
            download.statusLine = "Done"
            download.finish(.success(()))

            // Awaited inside run(), so the library is back under its limit before
            // the queue pulls the next video.
            await afterDownload?(download)
        } catch is CancellationError {
            if let recordID { await store.finish(id: recordID, status: .failed, filePath: nil) }
            download.state = .cancelled
            download.statusLine = "Cancelled"
            download.finish(.failure(CancellationError()))
        } catch {
            if let recordID { await store.finish(id: recordID, status: .failed, filePath: nil) }
            download.state = .failed(error.localizedDescription)
            download.statusLine = error.localizedDescription
            download.finish(.failure(error))
        }
    }

    /// Finds a downloaded video by its YouTube ID, in either on-disk layout.
    static func locateFile(videoID: String, in directory: URL) -> URL? {
        MediaLayout.locate(videoID: videoID, in: directory)
    }

    /// Writes Plex poster art next to the finished file. A cover that can't be
    /// built isn't worth failing the download over — the video is already there.
    private func makeCover(for download: Download) async {
        guard let destination = download.destination else { return }
        do {
            if let cover = try await CoverArt.ensure(
                videoURL: download.videoURL, videoFile: destination)
            {
                download.log.append("[cover] wrote \(cover.lastPathComponent)")
            }
        } catch {
            download.log.append("[cover] \(error.localizedDescription)")
        }
    }

    /// Pulls progress and destination info out of yt-dlp's output.
    private static func apply(line: String, to download: Download, directory: URL) {
        if let percent = parsePercent(line) {
            download.fraction = percent / 100
        }

        for marker in ["[download] Destination: ", "[Merger] Merging formats into \""] {
            guard let range = line.range(of: marker) else { continue }
            var path = String(line[range.upperBound...])
            if path.hasSuffix("\"") { path.removeLast() }
            let url = path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path)
            download.destination = url
        }

        // A file yt-dlp already has gets neither of the markers above — it just
        // says so and stops: "[download] <path> has already been downloaded".
        let already = " has already been downloaded"
        if line.hasPrefix("[download] "), line.hasSuffix(already) {
            let path = String(line.dropFirst("[download] ".count).dropLast(already.count))
            if !path.isEmpty {
                download.destination =
                    path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path)
            }
        }

        download.statusLine = line
    }

    private static func parsePercent(_ line: String) -> Double? {
        guard line.contains("[download]"), let percentIndex = line.firstIndex(of: "%") else {
            return nil
        }
        let digits = line[line.startIndex..<percentIndex]
            .reversed()
            .prefix { $0.isNumber || $0 == "." }
            .reversed()
        return Double(String(digits))
    }
}
