//
//  SettingsView.swift
//  kid-video-thing
//

import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            SlackSettings()
                .tabItem { Label("Slack", systemImage: "bubble.left.and.bubble.right") }
            PlexSettings()
                .tabItem { Label("Plex", systemImage: "play.tv") }
            ClaudeSettings()
                .tabItem { Label("Claude", systemImage: "wand.and.stars") }
        }
        .frame(width: 560)
    }
}

private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Library.self) private var library
    @Environment(LibraryPruner.self) private var pruner

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Downloads") {
                LabeledContent("Save videos to") {
                    HStack {
                        Text(settings.downloadDirectory.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Choose…", action: chooseDirectory)
                        if settings.downloadDirectory != AppSettings.defaultDownloadDirectory {
                            Button("Reset") {
                                settings.downloadDirectory = AppSettings.defaultDownloadDirectory
                            }
                        }
                    }
                }
            }

            Section("Disk Limit") {
                Stepper(
                    "Keep the library under \(settings.maxDiskUsageGB) GB",
                    value: $settings.maxDiskUsageGB, in: 1...10_000, step: 5)
                LabeledContent("Currently using") {
                    Text(usage)
                        .foregroundStyle(isOverLimit ? .orange : .secondary)
                }
                HStack {
                    Button("Prune Now") { pruner.pruneNow() }
                        .disabled(pruner.isPruning)
                    if pruner.isPruning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                Text(
                    """
                    When a download pushes the library past this, videos are deleted \
                    from the bottom of the list — never-watched ones first, oldest \
                    first — until it fits. A video that came from Slack gets an ❌ on \
                    its message.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if !pruner.activity.isEmpty {
                    ForEach(Array(pruner.activity.prefix(5).enumerated()), id: \.offset) {
                        _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Section("yt-dlp") {
                TextField("Path to yt-dlp", text: $settings.ytDlpPath, prompt: Text("Auto-detect"))
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(resolved == nil ? .red : .secondary)
            }
        }
        .formStyle(.grouped)
        .task { await library.refresh() }
    }

    private var used: Int64 {
        library.videos.compactMap(\.sizeBytes).reduce(0, +)
    }

    private var isOverLimit: Bool { used > settings.maxDiskUsageBytes }

    private var usage: String {
        "\(used.formatted(.byteCount(style: .file))) of "
            + settings.maxDiskUsageBytes.formatted(.byteCount(style: .file))
    }

    private var resolved: URL? {
        YTDLP.resolveExecutable(override: settings.ytDlpPath)
    }

    private var statusMessage: String {
        if let resolved {
            return "Using \(resolved.path(percentEncoded: false))"
        }
        return YTDLPError.notFound.localizedDescription
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.downloadDirectory
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.downloadDirectory = url
        }
    }
}

private struct PlexSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlexSync.self) private var plex
    @Environment(PlaylistSync.self) private var playlists

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Viewing Data") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Only shown when something is wrong, and it goes as soon as a
                // sync succeeds.
                if let error = plex.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Sync Now") { plex.syncNow() }
                        .disabled(plex.isSyncing)
                    if plex.isSyncing {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            }

            Section("Playlists") {
                Text(
                    """
                    React to a Slack message with an emoji and its videos join every \
                    Plex playlist with that emoji in its name — 🦕 files into \
                    "Dinosaurs 🦕". Removing the reaction takes them out again. \
                    Reacting to a playlist link files all of its videos at once.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if !playlists.activity.isEmpty {
                    ForEach(Array(playlists.activity.prefix(5).enumerated()), id: \.offset) {
                        _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Section("Refresh") {
                Stepper(
                    "Check Plex every \(settings.plexSyncMinutes) minute\(settings.plexSyncMinutes == 1 ? "" : "s")",
                    value: $settings.plexSyncMinutes, in: 1...720)
                    // A sleeping loop won't notice a new interval on its own.
                    .onChange(of: settings.plexSyncMinutes) { plex.restart() }
            }

            Section("Connection") {
                SecureField(
                    "Plex Token", text: $settings.plexToken,
                    prompt: Text("Auto-detected from Plex on this Mac"))
                Text(
                    """
                    Reads view counts and last-viewed dates from the Plex server on \
                    this Mac (localhost:32400), matching videos by the YouTube ID in \
                    their filename. Nothing is ever written back to Plex. Leave the \
                    token blank unless auto-detection fails.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        if plex.isSyncing { return "Syncing…" }
        if plex.lastError != nil { return "Last sync failed" }
        guard let synced = plex.lastSyncedAt else { return "Waiting for first sync" }
        return "\(plex.matchedCount) video(s) matched, \(synced.formatted(.relative(presentation: .named)))"
    }

    private var statusColor: Color {
        if plex.isSyncing { return .orange }
        if plex.lastError != nil { return .red }
        return plex.lastSyncedAt == nil ? .secondary : .green
    }
}

private struct ClaudeSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TitleCleaner.self) private var titles

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Connection") {
                SecureField(
                    "API Key", text: $settings.claudeAPIKey, prompt: Text("sk-ant-…"))
                Picker("Model", selection: $settings.claudeModel) {
                    ForEach(ClaudeClient.Model.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Text(settings.claudeModel.priceNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    """
                    Create a key at console.anthropic.com. Cleaning one title is a \
                    request of a few dozen tokens, so a library's worth costs a \
                    fraction of a cent. Leave the key blank and title cleanup is \
                    simply off.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Title Cleanup") {
                Toggle(
                    "Clean up titles automatically", isOn: $settings.cleanTitlesOnDownload)
                Text(
                    """
                    YouTube titles are written for search, not for reading: \
                    "Pizza Bean Mr Bean Cartoon Season 2 Full Episodes Mr Bean \
                    Official" is the "Pizza Bean" episode. Claude cuts it back and \
                    the video's folder is renamed on disk, so Plex shows the tidy \
                    name too. The YouTube ID stays in the filename, so nothing \
                    loses track of which video it is.

                    When a video joins a Plex playlist the title is cleaned again \
                    with the playlist's name as context — in "Mr Bean Cartoon" the \
                    show's name is repetition, so it goes. Taking the reaction off \
                    puts the earlier title back.

                    Every video also has a ✨ button in the list to do this by hand, \
                    and to undo it.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !titles.activity.isEmpty {
                Section("Recent Renames") {
                    ForEach(Array(titles.activity.prefix(8).enumerated()), id: \.offset) {
                        _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SlackSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SlackListener.self) private var slack

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Tokens") {
                SecureField(
                    "Bot User OAuth Token", text: $settings.slackBotToken,
                    prompt: Text("xoxb-…"))
                SecureField(
                    "App-Level Token", text: $settings.slackAppToken,
                    prompt: Text("xapp-…"))
                Text(
                    """
                    The bot token adds reactions. The app-level token (Basic Information → \
                    App-Level Tokens, scope `connections:write`) opens the Socket Mode \
                    connection that delivers messages.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Connection") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusText)
                    }
                }
                Toggle("Connect automatically at launch", isOn: $settings.slackAutoConnect)
                HStack {
                    if slack.status.isRunning {
                        Button("Disconnect") { slack.stop() }
                    } else {
                        Button("Connect") { slack.start() }
                            .disabled(!slack.canStart)
                    }
                    Spacer()
                }
            }

            Section("Resync") {
                HStack {
                    Button("Re-sync State") { slack.resync() }
                        .disabled(!slack.canSync)
                    if slack.isSyncing {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                Text(
                    """
                    Checks the last 30 days in every channel the bot is in. Downloads \
                    left mid-flight (still showing 👀) are restarted, and a ✅ whose \
                    file has since gone missing becomes ❌. Messages it has no record \
                    of are left untouched.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !slack.activity.isEmpty {
                Section("Recent Activity") {
                    ForEach(Array(slack.activity.prefix(8).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Section("Slack App Setup") {
                Text(
                    """
                    1. Enable Socket Mode.
                    2. Add bot scopes `channels:history`, `groups:history`, \
                    `channels:read`, `groups:read`, `reactions:read`, `reactions:write`, \
                    and `chat:write`, then install the app.
                    3. Under Event Subscriptions, add the bot events `message.channels` \
                    (and `message.groups` for private channels), plus `reaction_added` \
                    and `reaction_removed` for ❌ deletion and playlist filing.
                    4. Invite the bot to the channel you'll post links in.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch slack.status {
        case .off: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected(let team, let bot): return "Connected to \(team) as @\(bot)"
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        switch slack.status {
        case .off: return .secondary
        case .connecting: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }
}

#Preview {
    let settings = AppSettings()
    let store = VideoStore()
    let downloads = DownloadManager(settings: settings, store: store)
    let library = Library(store: store, downloads: downloads)
    let titles = TitleCleaner(settings: settings, store: store, library: library)
    let playlists = PlaylistSync(
        settings: settings, store: store, library: library, titles: titles)
    SettingsView()
        .environment(settings)
        .environment(downloads)
        .environment(library)
        .environment(
            SlackListener(
                settings: settings, downloads: downloads, store: store, playlists: playlists))
        .environment(PlexSync(settings: settings, store: store, library: library))
        .environment(LibraryPruner(settings: settings, store: store, library: library))
        .environment(playlists)
        .environment(titles)
}
