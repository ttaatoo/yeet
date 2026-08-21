//
//  Updater.swift
//  kero
//

import Combine
import Sparkle
import SwiftUI

/// App-wide Sparkle updater. A single instance owns the update lifecycle; the
/// "Check for Updates…" menu item and the Settings toggle both drive it.
///
/// The feed URL and the public EdDSA key are read from Info.plist
/// (`SUFeedURL`, `SUPublicEDKey`). Release / packaged builds of this fork
/// leave the feed empty so Sparkle cannot replace the app with official
/// egoist Kero from releases.kero.sh. See RELEASING.md.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    /// Gates the menu item: Sparkle can't start a check while one is already in
    /// flight, so the command disables itself until it's ready again.
    @Published private(set) var canCheckForUpdates = false

    /// Whether Sparkle checks for updates on its own schedule. Sparkle owns the
    /// persisted value (in `UserDefaults`); this mirror lets Settings bind to
    /// it and writes changes straight back through.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            // Same bundle id as official Kero (`sh.kero`) can inherit a
            // persisted "check automatically" from an earlier egoist install.
            // Never honor that when this build has no feed of its own.
            if Self.sparkleFeedURL.isEmpty {
                controller.updater.automaticallyChecksForUpdates = false
                if automaticallyChecksForUpdates {
                    automaticallyChecksForUpdates = false
                }
                return
            }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    private static var sparkleFeedURL: String {
        (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private init() {
        // Don't run the updater in debug builds. Starting it schedules a
        // background check and pops Sparkle's "check for updates
        // automatically?" permission prompt, which is just noise while
        // developing. Release starts it only when a feed is configured.
        #if DEBUG
        let startImmediately = false
        #else
        let startImmediately = !Self.sparkleFeedURL.isEmpty
        #endif
        controller = SPUStandardUpdaterController(
            startingUpdater: startImmediately,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        if Self.sparkleFeedURL.isEmpty {
            controller.updater.automaticallyChecksForUpdates = false
            automaticallyChecksForUpdates = false
        } else {
            // Seed from Sparkle's persisted value; didSet doesn't fire here.
            automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        }
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)

        // Force a silent check on launch when auto-checks are on. Starting the
        // updater only arms Sparkle's *scheduled* checker, which fires once its
        // interval (~a day) has elapsed since the last check — so a normal
        // relaunch checks nothing. Sparkle requires this forced check to run
        // immediately after the updater starts (calling it later interferes
        // with its scheduler), which is why it lives here and is gated on the
        // updater actually having been started.
        if startImmediately && automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    /// Runs Sparkle's user-facing update check (progress window and prompts).
    func checkForUpdates() {
        guard !Self.sparkleFeedURL.isEmpty else { return }
        controller.checkForUpdates(nil)
    }
}

/// The "Check for Updates…" application-menu command.
struct CheckForUpdatesView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
