//
//  SingleInstance.swift
//  kid-video-thing
//

import AppKit
import Foundation

/// Keeps one copy of the app running at a time.
///
/// Two copies fight over the Slack Socket Mode connection — each knocking the
/// other off with `too_many_websockets` — and both write the same download folder
/// and database. The copy already running wins: a second launch bows out before
/// it touches anything.
///
/// The claim is a file lock rather than a check of running applications, because
/// the lock also covers a copy launched outside its bundle, and the kernel drops
/// it when the process dies — so a crash can't leave the app permanently locked
/// out of starting.
enum SingleInstance {
    /// Held open for the life of the process. Closing it would release the lock,
    /// so this is never closed.
    private static var lockDescriptor: Int32 = -1

    /// True when this process now owns the app.
    static func claim() -> Bool {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        // If the lock file itself is unusable, don't refuse to start over it.
        guard descriptor >= 0 else { return true }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        // Stamp the owner into the file so a losing launch can name the winner —
        // asking the system for "some other copy with this bundle ID" can easily
        // finger a process that isn't the one holding the lock.
        ftruncate(descriptor, 0)
        let owner = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = owner.withCString { write(descriptor, $0, strlen($0)) }

        lockDescriptor = descriptor
        return true
    }

    /// Identifies the copy that already holds the app, for the log.
    static var holderDescription: String {
        guard let text = try? String(contentsOf: lockURL, encoding: .utf8),
            let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return "another copy" }

        guard let app = NSRunningApplication(processIdentifier: pid) else { return "pid \(pid)" }
        return "pid \(pid) at \(app.bundleURL?.path ?? "an unknown path")"
    }

    private static var lockURL: URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "kid-video-thing", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "instance.lock")
    }
}
