//
//  ContentView.swift
//  kid-video-thing
//
//  Created by Matt Hinz on 9/3/26.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(Library.self) private var library
    @Environment(PlexSync.self) private var plex
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var showInvalidURL = false
    @State private var panelWindow: NSWindow?

    private var canSubmit: Bool {
        DownloadManager.looksLikeVideoURL(urlText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            entryRow

            if showInvalidURL {
                Label("That doesn't look like a video URL.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Divider()

            if library.videos.isEmpty {
                emptyState
            } else {
                videoList
            }

            footer
        }
        .padding()
        // A menu bar panel has no resize handle, so the size is fixed here.
        .frame(width: 540, height: 460)
        // Guarded on identity: WindowReader reports on every update pass, and an
        // unconditional write here would spin SwiftUI in a loop.
        .background(WindowReader { if panelWindow !== $0 { panelWindow = $0 } })
        // Re-reads the library whenever any download changes state, which covers
        // both a new item appearing and one finishing.
        .task(id: downloads.downloads.map(\.state)) {
            await library.refresh()
        }
        // The panel is rebuilt each time it opens, so this catches up the viewing
        // figures on every look rather than waiting for the next scheduled tick.
        // `syncNow` is a no-op while a sync is already under way.
        .task {
            plex.syncNow()
        }
    }

    /// Closes the menu bar panel, for actions that move focus somewhere else —
    /// otherwise it hangs around in front of the window that just opened.
    ///
    /// `dismiss` is the supported route but doesn't reliably close a
    /// `MenuBarExtra` panel, so the window it's hosted in is ordered out as well.
    /// Whichever lands first, the other is a no-op.
    private func closePanel() {
        dismiss()
        panelWindow?.orderOut(nil)
    }

    private var entryRow: some View {
        HStack(spacing: 8) {
            TextField("Paste a YouTube URL", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                .onChange(of: urlText) { showInvalidURL = false }
            Button("Download", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No videos yet.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var videoList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(library.videos) { video in
                    VideoRow(video: video)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Open Folder") {
                try? settings.ensureDownloadDirectoryExists()
                NSWorkspace.shared.open(settings.downloadDirectory)
                closePanel()
            }
            SlackStatusBadge()
            Spacer()
            // With no Dock icon there's no app menu, so these live here.
            // The tap runs alongside SettingsLink's own action, so Settings still
            // opens — this only takes the panel down behind it.
            SettingsLink { Text("Settings…") }
                .simultaneousGesture(TapGesture().onEnded { closePanel() })
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .font(.callout)
    }

    private func submit() {
        guard canSubmit else {
            showInvalidURL = !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return
        }
        downloads.enqueue(urlText)
        urlText = ""
    }
}

/// Hands back the AppKit window hosting this view, so the menu bar panel can be
/// closed directly — SwiftUI offers no binding for a `MenuBarExtra`'s presentation.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view isn't in a window yet during make; it is by the next turn.
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}

/// Small footer indicator; only shows once Slack tokens have been entered.
private struct SlackStatusBadge: View {
    @Environment(SlackListener.self) private var slack

    var body: some View {
        switch slack.status {
        case .off where !slack.canStart:
            EmptyView()
        case .off:
            label("Slack off", color: .secondary)
        case .connecting:
            label("Slack connecting…", color: .orange)
        case .connected(let team, _):
            label("Slack: \(team)", color: .green)
        case .failed(let message):
            label("Slack error", color: .red).help(message)
        }
    }

    private func label(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
        }
        .padding(.leading, 6)
    }
}

/// One video. While it's downloading the row shows yt-dlp's progress; once it's
/// on disk the row becomes the video itself — poster, title, and how it's been
/// watched.
private struct VideoRow: View {
    let video: LibraryVideo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Poster(url: video.posterURL)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(video.title)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(video.url)
                    // The emoji reacted onto this video's Slack message — each one
                    // files it into the Plex playlist of the same name.
                    if !video.tags.isEmpty {
                        Text(video.tags.joined())
                            .help("In Plex playlists named with " + video.tags.joined(separator: " "))
                    }
                    Spacer()
                    actions
                }

                if let download = video.download, download.isActive {
                    DownloadProgress(download: download)
                } else {
                    details
                }
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var details: some View {
        switch video.status {
        case .failed:
            Label("Download failed", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        case .downloading:
            // A row left mid-download by a quit or crash.
            Text("Interrupted — picked up by the next re-sync")
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            if video.isMissing {
                Label("File not found on disk", systemImage: "questionmark.folder")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                ViewingStats(
                    viewCount: video.viewCount,
                    lastViewedAt: video.lastViewedAt,
                    sizeBytes: video.sizeBytes)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let download = video.download, !download.log.isEmpty {
            LogButton(download: download)
        }
        if video.fileExists {
            MagicRenameButton(video: video)
        }
        if video.fileExists, let file = video.file {
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                .buttonStyle(.link)
        }
        if let download = video.download, download.isActive {
            CancelButton(download: download)
        }
    }
}

/// Cleans a spammy YouTube title into something readable — and puts the original
/// back when it gets it wrong.
///
/// One button with two states rather than two buttons: a video is either wearing
/// its cleaned-up name or its original one, and the row is too narrow to explain
/// both at once.
private struct MagicRenameButton: View {
    @Environment(TitleCleaner.self) private var titles
    let video: LibraryVideo

    var body: some View {
        if titles.isWorking(video) {
            ProgressView().controlSize(.small)
        } else if video.isRenamed {
            Button {
                Task { await titles.undo(video) }
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Undo magic rename — put \"\(originalTitle)\" back")
        } else {
            Button {
                Task { await titles.clean(video) }
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .buttonStyle(.borderless)
            .disabled(!titles.isConfigured)
            .help(
                titles.isConfigured
                    ? "Magic rename — tidy this title with Claude"
                    : "Add a Claude API key in Settings to use magic rename")
        }
    }

    private var originalTitle: String {
        (video.originalName ?? "").replacingOccurrences(of: "_", with: " ")
    }
}

/// How often the video has been watched. Nothing fills these in yet — the shape
/// is here so a Plex sync has somewhere to land.
private struct ViewingStats: View {
    let viewCount: Int?
    let lastViewedAt: Date?
    let sizeBytes: Int64?

    var body: some View {
        HStack(spacing: 12) {
            Label(views, systemImage: "eye")
            Label(lastViewed, systemImage: "clock")
            if let sizeBytes {
                Label(
                    sizeBytes.formatted(.byteCount(style: .file)),
                    systemImage: "internaldrive")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var views: String {
        guard let viewCount else { return "— views" }
        return viewCount == 1 ? "1 view" : "\(viewCount) views"
    }

    private var lastViewed: String {
        guard let lastViewedAt else { return "never watched" }
        return lastViewedAt.formatted(.relative(presentation: .named))
    }
}

/// The yt-dlp progress a row shows while its download runs.
private struct DownloadProgress: View {
    @Bindable var download: Download

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let fraction = download.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            Text(download.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// yt-dlp's output, in a popover — a row is too small to expand inline now.
private struct LogButton: View {
    @Bindable var download: Download
    @State private var showLog = false

    var body: some View {
        Button("Log") { showLog.toggle() }
            .buttonStyle(.link)
            .popover(isPresented: $showLog) {
                ScrollView {
                    Text(download.log.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 420, height: 220)
            }
    }
}

private struct CancelButton: View {
    @Environment(DownloadManager.self) private var downloads
    let download: Download

    var body: some View {
        Button("Cancel") { downloads.cancel(download) }
            .buttonStyle(.link)
    }
}

/// The poster at list size. Decoding is deferred and downsampled so a long
/// library doesn't load a stack of full-size images.
private struct Poster: View {
    let url: URL?

    private static let width: CGFloat = 44
    private static let height: CGFloat = 66

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: Self.width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            let maxPixel = Int(Self.height * (NSScreen.main?.backingScaleFactor ?? 2))
            image = await Task.detached { CoverArt.thumbnail(at: url, maxPixel: maxPixel) }.value
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
    ContentView()
        .environment(settings)
        .environment(downloads)
        .environment(
            SlackListener(
                settings: settings, downloads: downloads, store: store, playlists: playlists))
        .environment(library)
        .environment(PlexSync(settings: settings, store: store, library: library))
        .environment(titles)
}
