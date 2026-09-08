//
//  LoginItem.swift
//  kid-video-thing
//

import Observation
import ServiceManagement

/// Whether macOS launches the app at login.
///
/// The system owns this the way Plex owns view counts: nothing is stored in our
/// own settings, because the checkbox has to agree with System Settings → General
/// → Login Items even when the user turns it off there. Every read asks
/// `SMAppService` afresh.
@Observable
final class LoginItem {
    /// The last thing registering or unregistering went wrong with, if anything.
    private(set) var error: String?

    /// Bumped after each change so the computed properties below re-read the
    /// system's status — `SMAppService.status` isn't observable on its own.
    private var generation = 0

    var status: SMAppService.Status {
        _ = generation
        return SMAppService.mainApp.status
    }

    var isEnabled: Bool { status == .enabled }

    /// True when the user has to switch the app on in System Settings by hand,
    /// usually because they turned it off there before.
    var needsApproval: Bool { status == .requiresApproval }

    func setEnabled(_ enabled: Bool) {
        error = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = error.localizedDescription
        }
        generation += 1
    }

    /// Re-reads the status, for when the user may have changed it elsewhere.
    func refresh() {
        generation += 1
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
