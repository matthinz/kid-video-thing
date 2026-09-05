//
//  kid_video_thingApp.swift
//  kid-video-thing
//
//  Created by Matt Hinz on 9/3/26.
//

import SwiftUI

/// The app's long-lived objects.
///
/// A menu bar panel is built only when it's opened, so these can't hang off the
/// view hierarchy — the Slack connection has to come up at launch whether or not
/// anyone clicks the icon. Keeping them here also means SwiftUI re-creating the
/// `App` struct can't quietly replace the listener that's already connected.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let settings: AppSettings
    let store: VideoStore
    let downloads: DownloadManager
    let slack: SlackListener
    let library: Library
    let playlists: PlaylistSync
    let plex: PlexSync
    let pruner: LibraryPruner

    private init() {
        settings = .shared
        store = VideoStore()
        downloads = DownloadManager(settings: settings, store: store)
        library = Library(store: store, downloads: downloads)
        playlists = PlaylistSync(settings: settings, store: store, library: library)
        slack = SlackListener(
            settings: settings, downloads: downloads, store: store, playlists: playlists)
        plex = PlexSync(settings: settings, store: store, library: library)
        pruner = LibraryPruner(settings: settings, store: store, library: library)

        downloads.afterDownload = { [pruner] download in
            await pruner.pruneIfNeeded(keeping: download.videoURL)
        }
    }

    func start() {
        // Plex is local and read-only, so it runs regardless of Slack.
        plex.start()
        guard settings.slackAutoConnect, slack.canStart else { return }
        slack.start()
    }
}

@main
struct kid_video_thingApp: App {
    // Deliberately computed, not stored: a stored property would build AppModel
    // before init's body runs, and constructing it opens the database and sweeps
    // interrupted downloads — trampling the copy that's already running.
    private var model: AppModel { .shared }

    init() {
        guard SingleInstance.claim() else {
            FileHandle.standardError.write(
                Data(
                    "[app] Already running as \(SingleInstance.holderDescription) — exiting.\n"
                        .utf8))
            // Before AppKit is up, so nothing to tear down and nothing touched yet.
            exit(0)
        }
        model.start()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environment(model.settings)
                .environment(model.downloads)
                .environment(model.slack)
                .environment(model.library)
                .environment(model.plex)
                .environment(model.pruner)
                .environment(model.playlists)
        } label: {
            MenuBarIcon()
                .environment(model.downloads)
                .environment(model.slack)
        }
        // A panel rather than a menu, so the URL field and download list work.
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model.settings)
                .environment(model.downloads)
                .environment(model.library)
                .environment(model.slack)
                .environment(model.plex)
                .environment(model.pruner)
                .environment(model.playlists)
        }
    }
}

/// The status item itself: shows what the app is up to at a glance.
private struct MenuBarIcon: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(SlackListener.self) private var slack

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        if downloads.isBusy { return "arrow.down.circle.fill" }
        if case .failed = slack.status { return "exclamationmark.triangle" }
        return "play.rectangle"
    }
}
