//
//  SlackListener.swift
//  kid-video-thing
//

import Foundation
import Observation

/// Maintains a Socket Mode connection, watches for YouTube links, and marks each
/// message with 👀 while downloading, swapping it for ✅ / ⚠️ when yt-dlp finishes.
/// An ❌ from a person deletes the downloaded file again. `resync()` reconciles
/// our records against channel history on demand.
@Observable
final class SlackListener {
    enum Status: Equatable {
        case off
        case connecting
        case connected(team: String, bot: String)
        case failed(String)

        var isRunning: Bool {
            self != .off
        }
    }

    private(set) var status: Status = .off
    private(set) var activity: [String] = []

    private let settings: AppSettings
    private let downloads: DownloadManager
    private let store: VideoStore
    private let playlists: PlaylistSync
    private var loop: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    /// Slack redelivers events on reconnect; this keeps us from re-downloading.
    private var handled: Set<String> = []
    /// The bot's own user ID, so its @mention can be stripped from message text.
    private var botUserID = ""
    /// Set while resync() is walking history, so the button can't be double-run.
    private(set) var isSyncing = false

    /// URLSession.shared's 60s request timeout kills an idle Socket Mode
    /// connection, so this session allows long gaps between frames.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    init(
        settings: AppSettings, downloads: DownloadManager, store: VideoStore,
        playlists: PlaylistSync
    ) {
        self.settings = settings
        self.downloads = downloads
        self.store = store
        self.playlists = playlists
        Task { await store.markInterruptedDownloadsFailed() }
    }

    private var client: SlackClient {
        SlackClient(botToken: settings.slackBotToken, appToken: settings.slackAppToken)
    }

    var canStart: Bool {
        !settings.slackBotToken.isEmpty && !settings.slackAppToken.isEmpty
    }

    func start() {
        guard loop == nil else { return }
        status = .connecting
        loop = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = .off
        note("Disconnected.")
    }

    /// Reconnects on any drop — Slack recycles Socket Mode connections regularly,
    /// so a disconnect is routine rather than an error.
    private func runLoop() async {
        var backoff: Duration = .seconds(1)

        while !Task.isCancelled {
            do {
                status = .connecting
                let identity = try await client.checkAuth()
                botUserID = identity.userID
                let url = try await client.openSocketConnection()
                status = .connected(team: identity.team, bot: identity.bot)
                note("Connected to \(identity.team) as @\(identity.bot).")
                backoff = .seconds(1)

                try await receiveMessages(from: url)
                note("Connection closed, reconnecting…")
            } catch is CancellationError {
                return
            } catch {
                status = .failed(error.localizedDescription)
                note("Connection problem: \(error.localizedDescription)")
            }

            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(60))
        }
    }

    /// A dropped WebSocket can leave `receive()` waiting forever with no error, so
    /// a ping every 30s doubles as keepalive and as a liveness check: when it
    /// fails, cancelling the socket makes `receive()` throw and the loop reconnects.
    private func startHeartbeat(for socket: URLSessionWebSocketTask) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                let alive = await withCheckedContinuation { continuation in
                    socket.sendPing { error in
                        continuation.resume(returning: error == nil)
                    }
                }
                if !alive {
                    self?.note("Heartbeat failed — dropping connection to reconnect.")
                    socket.cancel(with: .abnormalClosure, reason: nil)
                    return
                }
            }
        }
    }

    private func receiveMessages(from url: URL) async throws {
        let socket = Self.session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()

        let heartbeat = startHeartbeat(for: socket)
        defer {
            heartbeat.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            if self.socket === socket { self.socket = nil }
        }

        while !Task.isCancelled {
            let message = try await socket.receive()
            guard case .string(let text) = message,
                let data = text.data(using: .utf8),
                let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            FileHandle.standardError.write(Data("[slack:frame] \(text)\n".utf8))

            // Every envelope must be acked, or Slack retries it.
            if let envelopeID = frame["envelope_id"] as? String {
                let ack = ["envelope_id": envelopeID]
                if let ackData = try? JSONSerialization.data(withJSONObject: ack) {
                    try? await socket.send(.string(String(decoding: ackData, as: UTF8.self)))
                }
            }

            switch frame["type"] as? String {
            case "disconnect":
                return  // runLoop opens a fresh connection.
            case "events_api":
                if let payload = frame["payload"] as? [String: Any],
                    let event = payload["event"] as? [String: Any]
                {
                    handle(event: event)
                } else {
                    note("Received an events_api frame with no event payload")
                }
            default:
                break
            }
        }
    }

    private func handle(event: [String: Any]) {
        let type = event["type"] as? String ?? "?"
        if type == "reaction_added" || type == "reaction_removed" {
            handleReaction(event: event, added: type == "reaction_added")
            return
        }
        // An @mention arrives as app_mention, and also as message if that event is
        // subscribed too — the dedupe key below collapses the pair.
        guard type == "message" || type == "app_mention" else {
            note("Ignored \(type) event")
            return
        }
        // Skip edits, deletions, joins, and anything the bot itself posted.
        guard event["subtype"] == nil, event["bot_id"] == nil else {
            note("Ignored \(type) (\(event["subtype"] as? String ?? "from a bot"))")
            return
        }
        guard let text = event["text"] as? String,
            let channel = event["channel"] as? String,
            let timestamp = event["ts"] as? String
        else {
            note("Ignored \(type) with unexpected shape")
            return
        }

        let links = YouTubeLink.links(in: text)
        if links.isEmpty {
            if type == "app_mention" {
                note("Mentioned without a YouTube link: \(text.prefix(60))")
            }
            return
        }

        // An @mention is an explicit ask, so extra words are fine there. A plain
        // channel message only counts when it's nothing but the link(s) —
        // otherwise every video someone chats about would get downloaded.
        guard type == "app_mention" || isBareLinks(text, links: links) else {
            note("Link mentioned in conversation, not downloading: \(text.prefix(60))")
            return
        }

        for link in links {
            let key = "\(channel):\(timestamp):\(link)"
            guard !handled.contains(key) else { continue }
            handled.insert(key)
            Task { await process(link: link, channel: channel, timestamp: timestamp) }
        }
    }

    /// True when `text` is only the link(s), give or take the bot's own @mention
    /// and stray punctuation.
    ///
    /// The comparison runs on the normalized text — the same form `links(in:)`
    /// reads — because Slack delivers `&` as `&amp;`, and a raw message would
    /// never match the decoded links.
    private func isBareLinks(_ text: String, links: [String]) -> Bool {
        var remainder = YouTubeLink.normalize(text)
        if !botUserID.isEmpty {
            // Normalizing turns `<@U123>` into a bare `@U123`.
            for mention in ["<@\(botUserID)>", "@\(botUserID)"] {
                remainder = remainder.replacingOccurrences(of: mention, with: " ")
            }
        }
        for link in links {
            remainder = remainder.replacingOccurrences(of: link, with: " ")
        }
        return remainder.allSatisfy { $0.isWhitespace || $0.isPunctuation }
    }

    /// Downloads what a link points at and keeps the message's reactions in step.
    ///
    /// A playlist is expanded first, so each video it holds gets its own database
    /// row and its own file — without that, the message would only ever be linked
    /// to the playlist URL and a later ❌ would have nothing to delete. Expansion
    /// runs every time, so a playlist that has gained videos since we last looked
    /// picks them up.
    ///
    /// With `onlyMissing`, videos already downloaded (or deliberately deleted) are
    /// left alone — that's what makes re-reading a playlist cheap.
    private func process(
        link: String, channel: String, timestamp: String, onlyMissing: Bool = false
    ) async {
        let client = self.client
        note("Saw \(link)")
        try? await client.addReaction(.seen, channel: channel, timestamp: timestamp)

        func giveUp(_ reason: String) async {
            note(reason)
            try? await client.addReaction(.failed, channel: channel, timestamp: timestamp)
            try? await client.removeReaction(.seen, channel: channel, timestamp: timestamp)
        }

        var targets = [link]
        if YouTubeLink.isPlaylist(link) {
            guard let executable = YTDLP.resolveExecutable(override: settings.ytDlpPath) else {
                await giveUp(YTDLPError.notFound.localizedDescription)
                return
            }
            do {
                let ids = try await YTDLP.playlistVideoIDs(url: link, executable: executable)
                targets = ids.map(YouTubeLink.watchURL(videoID:))
                note("Playlist \(Self.shorten(link)) holds \(targets.count) video(s)")
            } catch {
                await giveUp("Couldn't read playlist \(link): \(error.localizedDescription)")
                return
            }
            guard !targets.isEmpty else {
                await giveUp("Playlist \(link) is empty or unreadable")
                return
            }
        }

        // Skip what we already have. A deliberately deleted video is skipped
        // whatever the mode, or a ❌'d playlist would refill itself on every sync.
        let existing = await store.entries(channel: channel, messageTS: timestamp)
        let pending = targets.filter { target in
            guard let entry = existing.first(where: { $0.url == target }) else { return true }
            if entry.status == .deleted { return false }
            guard onlyMissing, entry.status == .done, let path = entry.filePath else { return true }
            return !FileManager.default.fileExists(atPath: path)
        }

        // Queue everything first so the downloader can work straight through. The
        // database row for each is DownloadManager's job, not ours.
        var started: [(video: String, download: Download)] = []
        var failures = 0
        for target in pending {
            guard
                let download = downloads.enqueue(
                    target, origin: .slack(channel: channel, timestamp: timestamp))
            else {
                note("Ignored unusable link \(target)")
                failures += 1
                continue
            }
            started.append((target, download))
        }

        for (video, download) in started {
            switch await download.result() {
            case .success:
                note("Downloaded \(download.destination?.lastPathComponent ?? video)")
            case .failure(let error):
                note("Failed \(video): \(error.localizedDescription)")
                failures += 1
            }
        }

        if failures == 0 {
            try? await client.addReaction(.done, channel: channel, timestamp: timestamp)
            // A retry that worked shouldn't leave the old ⚠️ sitting there.
            try? await client.removeReaction(.failed, channel: channel, timestamp: timestamp)
        } else {
            note("\(failures) of \(pending.count) download(s) failed for \(link)")
            try? await client.addReaction(.failed, channel: channel, timestamp: timestamp)
        }
        // The 👀 only means "working on it", so it goes once ✅ / ⚠️ is up.
        try? await client.removeReaction(.seen, channel: channel, timestamp: timestamp)
    }

    /// Acts on a reaction someone put on, or took off, a message.
    ///
    /// ❌ deletes. Every other emoji is a filing instruction: PlaylistSync looks
    /// for a Plex playlist with that emoji in its name.
    private func handleReaction(event: [String: Any], added: Bool) {
        guard let name = event["reaction"] as? String else { return }
        // Our own reactions come back as events too; acting on them would loop.
        guard let user = event["user"] as? String, user != botUserID else { return }
        guard let item = event["item"] as? [String: Any],
            let channel = item["channel"] as? String,
            let timestamp = item["ts"] as? String
        else {
            note("Ignored a reaction event with unexpected shape")
            return
        }

        if name == SlackClient.Reaction.deleted.rawValue {
            // Taking an ❌ back off doesn't bring the files back.
            guard added else { return }
            let key = "delete:\(channel):\(timestamp)"
            guard !handled.contains(key) else { return }
            handled.insert(key)
            Task { await self.delete(channel: channel, timestamp: timestamp) }
            return
        }

        Task {
            await self.playlists.apply(
                reaction: name, added: added, channel: channel, timestamp: timestamp)
        }
    }

    private func delete(channel: String, timestamp: String) async {
        let client = self.client

        // Anything still running has to stop before its file can go, and its
        // final path only reaches the store once it does.
        for download in downloads.downloads(fromSlackMessage: channel, timestamp: timestamp) {
            if download.isActive {
                downloads.cancel(download)
                _ = await download.result()
            }
            downloads.remove(download)
        }

        let entries = await store.entries(channel: channel, messageTS: timestamp)
            .filter { $0.status != .deleted }
        guard !entries.isEmpty else {
            note("❌ on a message with nothing of ours to delete — ignoring")
            handled.remove("delete:\(channel):\(timestamp)")
            return
        }

        var failures: [String] = []
        for entry in entries {
            let name = entry.filePath.map { URL(filePath: $0).lastPathComponent } ?? entry.url
            do {
                if let path = entry.filePath, FileManager.default.fileExists(atPath: path) {
                    // Takes the video's folder and its poster along with it.
                    try MediaLayout.remove(URL(filePath: path))
                }
                await store.finish(id: entry.id, status: .deleted, filePath: nil)
                note("Deleted \(name)")
            } catch {
                note("Could not delete \(name): \(error.localizedDescription)")
                failures.append(name)
            }
        }

        guard failures.isEmpty else {
            // Let a repeated ❌ try the stragglers again.
            handled.remove("delete:\(channel):\(timestamp)")
            try? await client.addReaction(.failed, channel: channel, timestamp: timestamp)
            return
        }

        try? await client.removeReaction(.done, channel: channel, timestamp: timestamp)
        try? await client.addReaction(.deleted, channel: channel, timestamp: timestamp)
    }

    // MARK: - Manual resync

    /// How far back a resync looks.
    private static let resyncWindow: TimeInterval = 30 * 24 * 60 * 60

    var canSync: Bool {
        if case .connected = status { return !isSyncing }
        return false
    }

    /// Walks a month of history in every channel the bot is in and lines our
    /// records up with what the channel shows. Deliberately conservative: it only
    /// re-enqueues downloads that were visibly interrupted (👀 still showing), and
    /// it never removes a reaction just because we have no record of the message —
    /// an empty database means we know nothing, not that nothing happened.
    func resync() {
        guard canSync else { return }
        isSyncing = true
        Task {
            await runResync()
            isSyncing = false
        }
    }

    private func runResync() async {
        let since = Date().addingTimeInterval(-Self.resyncWindow).timeIntervalSince1970
        let client = self.client

        let channels: [String]
        do {
            channels = try await client.joinedChannels()
        } catch {
            note("Resync failed: \(error.localizedDescription)")
            return
        }

        note("Resyncing \(channels.count) channel(s) over the last 30 days…")
        var scanned = 0
        for channel in channels {
            guard !Task.isCancelled else { return }
            do {
                let history = try await client.allHistory(channel: channel, since: since)
                if history.truncated {
                    note("\(channel) has more history than one resync can walk — checked the newest \(history.messages.count).")
                }
                for message in history.messages {
                    await reconcile(message: message, channel: channel)
                    scanned += 1
                }
            } catch {
                note("Could not read history for \(channel): \(error.localizedDescription)")
            }
        }
        note("Resync finished — \(scanned) message(s) checked.")
    }

    /// Reconciles one historical message. The message's own reactions say what we
    /// last told the channel; the database says what we actually have. Every
    /// message carrying a link gets a line in the log saying what both sides
    /// looked like and what was done about it.
    private func reconcile(message: [String: Any], channel: String) async {
        guard message["subtype"] == nil, message["bot_id"] == nil,
            let text = message["text"] as? String,
            let timestamp = message["ts"] as? String
        else { return }

        let links = YouTubeLink.links(in: text)
        guard !links.isEmpty else { return }

        let reactions = Self.reactions(in: message)
        let rawEntries = await store.entries(channel: channel, messageTS: timestamp)
        // Filenames, folder layout and posters are all brought up to date before
        // the reaction bookkeeping below, which depends on knowing the real paths.
        let (entries, extras) = await tidy(rawEntries)

        let subject = links.map(Self.shorten).joined(separator: ", ")
        let slackState = Self.describe(reactions: reactions, botUserID: botUserID)
        let dbState = Self.describe(entries: entries)

        func report(_ action: String) {
            note("\(subject) — slack: \(slackState) | db: \(dbState) → \(action)\(extras)")
        }

        // History has no app_mention type, so the @mention has to be spotted in
        // the text itself to apply the same "was this actually a request?" rule.
        let mentioned = !botUserID.isEmpty && text.contains("<@\(botUserID)>")
        guard mentioned || isBareLinks(text, links: links) else {
            report("no action (link was mentioned in conversation, never a request)")
            return
        }
        // A message can arrive as a live event and in this sweep at once; leave
        // anything already in flight alone.
        guard !isInFlight(channel: channel, timestamp: timestamp) else {
            report("no action (already being handled right now)")
            return
        }

        let client = self.client
        let ours = { (reaction: SlackClient.Reaction) in
            (reactions[reaction.rawValue] ?? []).contains(self.botUserID)
        }

        // 👀 with no ✅/⚠️ means we were mid-download when we stopped. That's the
        // one case we know for certain needs picking back up.
        if ours(.seen), !ours(.done), !ours(.failed) {
            var queued: [String] = []
            for link in links {
                let key = "\(channel):\(timestamp):\(link)"
                guard !handled.contains(key) else { continue }
                handled.insert(key)
                queued.append(Self.shorten(link))
                Task { await self.process(link: link, channel: channel, timestamp: timestamp) }
            }
            report(
                queued.isEmpty
                    ? "no action (interrupted, but already queued)"
                    : "re-queueing \(queued.count) interrupted download(s): \(queued.joined(separator: ", "))"
            )
            return
        }

        // Our own ❌ with the file present again means we wrote it off too early —
        // most likely the video was moved by hand and has since been found. No
        // human ❌ can be involved here; that case returned above.
        let onDisk = entries.contains { entry in
            entry.status == .done
                && entry.filePath.map { FileManager.default.fileExists(atPath: $0) } == true
        }
        if ours(.deleted), onDisk {
            try? await client.removeReaction(.deleted, channel: channel, timestamp: timestamp)
            try? await client.addReaction(.done, channel: channel, timestamp: timestamp)
            report("file is here after all — swapped ❌ back for ✅")
            return
        }

        // A playlist is never finished — it can gain videos at any time, so it's
        // re-read on every sync regardless of what the reactions say. Videos we
        // already hold are skipped, so this costs one index fetch.
        let playlists = links.filter(YouTubeLink.isPlaylist)
        if !playlists.isEmpty {
            for playlist in playlists {
                let key = "\(channel):\(timestamp):\(playlist)"
                guard !handled.contains(key) else { continue }
                handled.insert(key)
                Task {
                    await self.process(
                        link: playlist, channel: channel, timestamp: timestamp, onlyMissing: true)
                    // Released so a later sync in this session can look again.
                    self.handled.remove(key)
                }
            }
            report("re-reading playlist for videos we don't have yet")
            return
        }

        // ⚠️ means the last attempt failed. Retrying also (re)creates the database
        // row, so this repairs a missing record as much as a missing file. Links
        // we already have, or that were deliberately deleted, are left out.
        if ours(.failed) {
            var retrying: [String] = []
            for link in links {
                let entry = entries.first { $0.url == link }
                switch entry?.status {
                case .done, .deleted:
                    continue
                default:
                    let key = "\(channel):\(timestamp):\(link)"
                    guard !handled.contains(key) else { continue }
                    handled.insert(key)
                    retrying.append(Self.shorten(link))
                    Task { await self.process(link: link, channel: channel, timestamp: timestamp) }
                }
            }
            if !retrying.isEmpty {
                report("retrying \(retrying.count) failed download(s): \(retrying.joined(separator: ", "))")
                return
            }
            // Nothing to retry — fall through in case the ✅ check still applies.
        }

        guard ours(.done) else {
            report(
                ours(.failed)
                    ? "no action (⚠️ is there, but every link is already done or deleted)"
                    : "no action (nothing claims we have it)")
            return
        }

        // ✅ claims we have the file. Verify that, but only where we have a record
        // to verify against — no record means no knowledge, so leave it be.
        let known = entries.filter { $0.status == .done && $0.filePath != nil }
        guard !known.isEmpty else {
            report("no action (✅ is there but we have no recorded file to check)")
            return
        }
        let missing = known.filter { !FileManager.default.fileExists(atPath: $0.filePath!) }
        guard missing.count == known.count else {
            report(
                missing.isEmpty
                    ? "no action (✅ matches the file on disk)"
                    : "no action (\(missing.count) of \(known.count) files gone, but some remain)"
            )
            return
        }

        for entry in known {
            await store.finish(id: entry.id, status: .deleted, filePath: nil)
        }
        try? await client.removeReaction(.done, channel: channel, timestamp: timestamp)
        try? await client.addReaction(.deleted, channel: channel, timestamp: timestamp)
        report("file(s) gone from disk — swapped ✅ for ❌ and marked deleted")
    }

    /// "👀 (ours), ✅ (ours + 1 other)" — what the message currently shows.
    private static func describe(reactions: [String: [String]], botUserID: String) -> String {
        var parts: [String] = []
        for reaction in [SlackClient.Reaction.seen, .done, .failed, .deleted] {
            let users = reactions[reaction.rawValue] ?? []
            guard !users.isEmpty else { continue }
            let others = users.filter { $0 != botUserID }.count
            let who =
                switch (users.contains(botUserID), others) {
                case (true, 0): "ours"
                case (true, let count): "ours + \(count) other"
                case (false, let count): "\(count) other"
                }
            parts.append(":\(reaction.rawValue): (\(who))")
        }
        return parts.isEmpty ? "no reactions" : parts.joined(separator: ", ")
    }

    /// "done, file present; failed" — what we have on record for the message. A
    /// playlist can hold dozens of videos, so past a handful it's counted instead.
    private static func describe(entries: [VideoStore.Entry]) -> String {
        guard !entries.isEmpty else { return "no record" }

        func fileState(_ entry: VideoStore.Entry) -> String {
            guard let path = entry.filePath else { return entry.status.rawValue }
            let present = FileManager.default.fileExists(atPath: path)
            return "\(entry.status.rawValue), file \(present ? "present" : "MISSING")"
        }

        guard entries.count > 4 else { return entries.map(fileState).joined(separator: "; ") }

        let missing = entries.filter {
            $0.status == .done && $0.filePath.map { !FileManager.default.fileExists(atPath: $0) } == true
        }
        let counts = Dictionary(grouping: entries, by: \.status)
            .map { "\($0.value.count) \($0.key.rawValue)" }
            .sorted()
            .joined(separator: ", ")
        return "\(entries.count) videos (\(counts))"
            + (missing.isEmpty ? "" : ", \(missing.count) file(s) MISSING")
    }

    /// Trims a link down to something that fits on one log line.
    private static func shorten(_ link: String) -> String {
        var short = link
        for prefix in ["https://", "http://", "www."] where short.hasPrefix(prefix) {
            short.removeFirst(prefix.count)
        }
        return short.count > 48 ? short.prefix(47) + "…" : short
    }

    /// Brings the files behind a message's records up to date: reconnects records
    /// with no filename, moves videos still sitting loose in the download folder
    /// into their own, and writes any missing poster. Returns the entries with
    /// their corrected paths, plus a phrase to tack onto the log line.
    private func tidy(_ entries: [VideoStore.Entry]) async -> ([VideoStore.Entry], String) {
        var updated: [VideoStore.Entry] = []
        var linked = 0
        var moved = 0
        var restored = 0
        var covered = 0
        var failed = 0

        for var entry in entries {
            // `deleted` rows are included because one may have been written off in
            // error — a file moved by hand looks identical to a file removed.
            guard entry.status == .done || entry.status == .deleted else {
                updated.append(entry)
                continue
            }

            // A recorded path can be stale as easily as absent: early downloads
            // never captured one, and moving a video by hand invalidates it. The
            // output template ends in `[<id>]`, so the file can be found by ID
            // wherever it now sits.
            var file = entry.filePath.map { URL(filePath: $0) }
            if file == nil || !FileManager.default.fileExists(atPath: file!.path) {
                if let id = CoverArt.videoID(from: entry.url),
                    let found = DownloadManager.locateFile(
                        videoID: id, in: settings.downloadDirectory)
                {
                    file = found
                    linked += 1
                    note("Matched \(id) to \(found.lastPathComponent)")
                }
            }
            guard let located = file, FileManager.default.fileExists(atPath: located.path) else {
                updated.append(entry)
                continue
            }

            var current = located
            if !MediaLayout.isOrganized(current) {
                do {
                    current = try MediaLayout.organize(current)
                    moved += 1
                    note("Moved \(current.lastPathComponent) into its own folder")
                } catch {
                    failed += 1
                    note("Could not move \(current.lastPathComponent): \(error.localizedDescription)")
                }
            }

            // A file belongs to one video. Locating by ID can turn up a file that
            // another live row already owns — the same video posted under two
            // URLs — and claiming it here is what produced duplicate `done` rows
            // pointing at a single file.
            let claimants = await store.claimants(filePath: current.path, excluding: entry.id)
            guard claimants.isEmpty else {
                note(
                    "\(current.lastPathComponent) already belongs to row \(claimants[0]) — "
                        + "leaving \(entry.id) alone.")
                updated.append(entry)
                continue
            }

            // Rows downloaded before sizes were recorded get one now.
            if entry.sizeBytes == nil {
                await store.recordSize(id: entry.id, filePath: current.path)
            }

            if current.path != entry.filePath || entry.status != .done {
                if entry.status == .deleted {
                    restored += 1
                    note("\(current.lastPathComponent) is still here after all — undeleting")
                }
                await store.finish(id: entry.id, status: .done, filePath: current.path)
                entry.filePath = current.path
                entry.status = .done
            }

            do {
                if try await CoverArt.ensure(videoURL: entry.url, videoFile: current) != nil {
                    covered += 1
                }
            } catch {
                failed += 1
                note("Cover art for \(current.lastPathComponent) failed: \(error.localizedDescription)")
            }
            updated.append(entry)
        }

        var parts: [String] = []
        if linked > 0 { parts.append("linked \(linked) file(s) to their records") }
        if moved > 0 { parts.append("moved \(moved) into per-video folders") }
        if restored > 0 { parts.append("restored \(restored) wrongly-deleted record(s)") }
        if covered > 0 { parts.append("generated \(covered) cover(s)") }
        if failed > 0 { parts.append("\(failed) failed") }
        return (updated, parts.isEmpty ? "" : "; " + parts.joined(separator: ", "))
    }

    /// True while a live event for this message is still being worked on.
    private func isInFlight(channel: String, timestamp: String) -> Bool {
        handled.contains { key in
            key.hasPrefix("\(channel):\(timestamp):") || key == "delete:\(channel):\(timestamp)"
        }
    }

    /// Flattens a message's `reactions` array into emoji name → reacting user IDs.
    private static func reactions(in message: [String: Any]) -> [String: [String]] {
        var byName: [String: [String]] = [:]
        for case let reaction as [String: Any] in message["reactions"] as? [Any] ?? [] {
            guard let name = reaction["name"] as? String else { continue }
            byName[name, default: []] += (reaction["users"] as? [String]) ?? []
        }
        return byName
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("[slack] \(message)\n".utf8))
        activity.insert(message, at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
    }
}
