//
//  AppSettings.swift
//  kid-video-thing
//

import Foundation
import Observation

/// User-configurable settings, persisted in UserDefaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let downloadDirectory = "downloadDirectory"
        static let ytDlpPath = "ytDlpPath"
        static let slackBotToken = "slackBotToken"
        static let slackAppToken = "slackAppToken"
        static let slackAutoConnect = "slackAutoConnect"
        static let plexSyncMinutes = "plexSyncMinutes"
        static let plexToken = "plexToken"
        static let maxDiskUsageGB = "maxDiskUsageGB"
    }

    /// How often to re-read viewing figures from Plex, when nothing is set.
    static let defaultPlexSyncMinutes = 15

    /// How much disk the video library may use before old videos are dropped.
    static let defaultMaxDiskUsageGB = 50

    /// Where downloaded videos land. Defaults to ~/Media/Kid Video Thing.
    var downloadDirectory: URL {
        didSet { defaults.set(downloadDirectory.path, forKey: Key.downloadDirectory) }
    }

    /// Optional override for the yt-dlp binary. Empty means "look in the usual places".
    var ytDlpPath: String {
        didSet { defaults.set(ytDlpPath, forKey: Key.ytDlpPath) }
    }

    /// Bot User OAuth token (`xoxb-…`) — used for reactions.add and auth.test.
    var slackBotToken: String {
        didSet { defaults.set(slackBotToken, forKey: Key.slackBotToken) }
    }

    /// App-level token (`xapp-…`) with `connections:write` — opens Socket Mode.
    var slackAppToken: String {
        didSet { defaults.set(slackAppToken, forKey: Key.slackAppToken) }
    }

    /// Whether to connect to Slack automatically at launch.
    var slackAutoConnect: Bool {
        didSet { defaults.set(slackAutoConnect, forKey: Key.slackAutoConnect) }
    }

    /// Minutes between Plex refreshes. Never less than 1 — a zero would spin the
    /// sync loop with no pause at all.
    var plexSyncMinutes: Int {
        get { storedPlexSyncMinutes }
        set {
            storedPlexSyncMinutes = max(1, newValue)
            defaults.set(storedPlexSyncMinutes, forKey: Key.plexSyncMinutes)
        }
    }

    /// Overrides the token read from the local Plex install. Usually empty.
    var plexToken: String {
        didSet { defaults.set(plexToken, forKey: Key.plexToken) }
    }

    /// Ceiling for the whole video library, in gigabytes. Going over it deletes
    /// the least interesting videos until the library fits again.
    var maxDiskUsageGB: Int {
        get { storedMaxDiskUsageGB }
        set {
            storedMaxDiskUsageGB = max(1, newValue)
            defaults.set(storedMaxDiskUsageGB, forKey: Key.maxDiskUsageGB)
        }
    }

    // Clamping happens in the setters above, against these two.
    //
    // It cannot happen in a `didSet`: @Observable rewrites a stored property into
    // a computed one, so assigning to the property from inside its own `didSet`
    // calls the setter again instead of being suppressed, and recurses until the
    // stack gives out. Observation still tracks these, because the public getters
    // read them.
    private var storedPlexSyncMinutes: Int
    private var storedMaxDiskUsageGB: Int

    /// The ceiling in bytes. Gigabytes here are the decimal kind, to match how
    /// sizes are shown in the list.
    var maxDiskUsageBytes: Int64 {
        Int64(maxDiskUsageGB) * 1_000_000_000
    }

    private let defaults: UserDefaults

    static var defaultDownloadDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Media", directoryHint: .isDirectory)
            .appending(path: "Kid Video Thing", directoryHint: .isDirectory)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let path = defaults.string(forKey: Key.downloadDirectory), !path.isEmpty {
            downloadDirectory = URL(filePath: path, directoryHint: .isDirectory)
        } else {
            downloadDirectory = Self.defaultDownloadDirectory
        }
        ytDlpPath = defaults.string(forKey: Key.ytDlpPath) ?? ""
        slackBotToken = defaults.string(forKey: Key.slackBotToken) ?? ""
        slackAppToken = defaults.string(forKey: Key.slackAppToken) ?? ""
        slackAutoConnect = defaults.bool(forKey: Key.slackAutoConnect)
        // `integer(forKey:)` can't tell "unset" from zero, so ask first.
        storedPlexSyncMinutes =
            defaults.object(forKey: Key.plexSyncMinutes) == nil
            ? Self.defaultPlexSyncMinutes
            : max(1, defaults.integer(forKey: Key.plexSyncMinutes))
        plexToken = defaults.string(forKey: Key.plexToken) ?? ""
        storedMaxDiskUsageGB =
            defaults.object(forKey: Key.maxDiskUsageGB) == nil
            ? Self.defaultMaxDiskUsageGB
            : max(1, defaults.integer(forKey: Key.maxDiskUsageGB))
    }

    /// Creates the download directory if it isn't there yet.
    func ensureDownloadDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: downloadDirectory, withIntermediateDirectories: true)
    }
}
